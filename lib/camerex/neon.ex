defmodule Camerex.Neon do
  @moduledoc """
  Núcleo puro do efeito neon (contrato §4): traçado de bordas (Evision) e
  composição por máximo (Nx). Todos os tensores de imagem são RGB.
  """

  @doc """
  Bordas internas (CLAHE + bilateral + Canny dentro da máscara erodida) +
  silhueta (Canny da máscara), fechadas (CLOSE 3×3) e dilatadas (2×2).
  `(rgb u8 {h,w,3}, mask u8 {h,w}, detail: 0.0..1.0 default 0.5)` →
  edges u8 `{h, w}` 0|255.
  """
  @spec trace_edges(Nx.Tensor.t(), Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  def trace_edges(rgb, mask, opts \\ []) do
    detail = Keyword.get(opts, :detail, 0.5)
    canny_lo = round(100 - 80 * detail)
    canny_hi = round(220 - 160 * detail)

    rgb_mat = Evision.Mat.from_nx_2d(rgb)
    mask_mat = Evision.Mat.from_nx(mask)
    clahe = Evision.createCLAHE(clipLimit: 3.0, tileGridSize: {8, 8})

    gray =
      rgb_mat
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2GRAY())
      |> then(&Evision.CLAHE.apply(clahe, &1))

    inner =
      gray
      |> Evision.bilateralFilter(9, 60.0, 60.0)
      |> Evision.canny(canny_lo, canny_hi)
      |> Evision.min(Evision.erode(mask_mat, kernel({5, 5})))

    inner
    |> Evision.max(Evision.canny(mask_mat, 50, 150))
    |> Evision.morphologyEx(Evision.Constant.cv_MORPH_CLOSE(), kernel({3, 3}))
    |> Evision.dilate(kernel({2, 2}))
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  @doc """
  Composição por MÁXIMO (nunca soma): a linha fica na cor exata do preset
  e os halos só preenchem ao redor. `input` é edges (foto) ou trail
  (vídeo), f32 `{h, w}` em [0, 1]; devolve RGB u8 `{h, w, 3}`.

  opts: `halo:` 0..1 (default 0.6) · `bloom:` 0..1 (default 0.0; camada de
  brilho atmosférico sigma ~22, neutra em 0) · `duotone_weights:` nil | f32
  `{h, w}` (2 ou 3 cores) · `current_edges:` nil | f32 `{h, w}` (vídeo).
  """
  @spec compose(Nx.Tensor.t(), [Camerex.Neon.Palette.color()], keyword()) :: Nx.Tensor.t()
  def compose(input, colors, opts \\ []) do
    halo = Keyword.get(opts, :halo, 0.6)
    bloom = Keyword.get(opts, :bloom, 0.0)
    weights = Keyword.get(opts, :duotone_weights)
    current_edges = Keyword.get(opts, :current_edges) || input

    w_big = min(0.92 * halo, 1.0)
    w_mid = min(1.33 * halo, 1.0)
    w_atmo = min(0.6 * bloom, 1.0)

    halo_big = input |> gaussian_blur(8.0) |> Nx.multiply(w_big)
    halo_mid = input |> gaussian_blur(3.0) |> Nx.multiply(w_mid)
    halo_atmo = input |> gaussian_blur(22.0) |> Nx.multiply(w_atmo)

    intens =
      halo_big |> Nx.max(halo_mid) |> Nx.max(halo_atmo) |> Nx.max(current_edges)

    intens
    |> Nx.new_axis(-1)
    |> Nx.multiply(color_field(colors, weights))
    |> Nx.clip(0, 255)
    |> Nx.as_type(:u8)
  end

  @doc """
  Pesos do duotone (f32 `{h, w}`): sigmoide horizontal
  `1 / (1 + exp(-(x - split_x) / blend_px))` — ~0 à esquerda do split,
  ~1 à direita, transição de ~`blend_px` pixels (default 24, contrato §4).
  """
  @spec duotone_weights(pos_integer(), pos_integer(), float(), number()) :: Nx.Tensor.t()
  def duotone_weights(h, w, split_x, blend_px \\ 24) do
    {h, w}
    |> Nx.iota(axis: 1, type: :f32)
    |> Nx.subtract(split_x)
    |> Nx.divide(blend_px)
    |> Nx.negate()
    |> Nx.exp()
    |> Nx.add(1.0)
    |> then(&Nx.divide(1.0, &1))
  end

  @doc """
  Mediana das coordenadas-x dos pixels > 0 (como `np.median`: contagem par
  tira a média dos dois centrais). Máscara vazia → `w / 2`.
  """
  @spec mask_median_x(Nx.Tensor.t()) :: float()
  def mask_median_x(mask) do
    {_h, w} = Nx.shape(mask)
    on = Nx.greater(mask, 0)
    count = on |> Nx.sum() |> Nx.to_number()

    if count == 0 do
      w / 2
    else
      # empurra os x dos pixels apagados para o fim (sentinela w) e ordena:
      # os `count` primeiros do flatten são exatamente os x dos acesos
      sorted =
        on
        |> Nx.select(Nx.iota(Nx.shape(mask), axis: 1), w)
        |> Nx.flatten()
        |> Nx.sort()

      mid = div(count, 2)

      if rem(count, 2) == 1 do
        1.0 * Nx.to_number(sorted[mid])
      else
        (Nx.to_number(sorted[mid - 1]) + Nx.to_number(sorted[mid])) / 2
      end
    end
  end

  @doc """
  Linhas extremas com pixel aceso (`{y_top, y_bottom}`); máscara vazia
  devolve `{0, h - 1}`. Fonte da extensão vertical do degradê.
  """
  @spec mask_y_bounds(Nx.Tensor.t()) :: {non_neg_integer(), non_neg_integer()}
  def mask_y_bounds(mask) do
    {h, _w} = Nx.shape(mask)
    on_rows = mask |> Nx.greater(0) |> Nx.any(axes: [1])

    if on_rows |> Nx.sum() |> Nx.to_number() == 0 do
      {0, h - 1}
    else
      rows = Nx.iota({h})
      y_top = on_rows |> Nx.select(rows, h) |> Nx.reduce_min() |> Nx.to_number()
      y_bottom = on_rows |> Nx.select(rows, -1) |> Nx.reduce_max() |> Nx.to_number()
      {y_top, y_bottom}
    end
  end

  @doc """
  Rampa f32 `{h, w}`: 0 em `y_top`, 1 em `y_bottom`, clampada fora do
  intervalo e constante por coluna (pesos do modo gradiente).
  """
  @spec vertical_weights(pos_integer(), pos_integer(), number(), number()) :: Nx.Tensor.t()
  def vertical_weights(h, w, y_top, y_bottom) do
    span = max(y_bottom - y_top, 1)

    {h, w}
    |> Nx.iota(axis: 0, type: :f32)
    |> Nx.subtract(y_top)
    |> Nx.divide(span)
    |> Nx.clip(0.0, 1.0)
  end

  defp gaussian_blur(t, sigma) do
    t
    |> Evision.Mat.from_nx()
    |> Evision.gaussianBlur({0, 0}, sigma)
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  # mono: cor constante {3}; gradiente: campo {h, w, 3} interpolado por pixel
  defp color_field([{r, g, b}], _weights), do: Nx.tensor([r, g, b], type: :f32)

  defp color_field([c0, c1], %Nx.Tensor{} = weights) do
    lerp(c0, c1, Nx.new_axis(weights, -1))
  end

  defp color_field([c0, c1, c2], %Nx.Tensor{} = weights) do
    w = Nx.new_axis(weights, -1)
    t = Nx.multiply(w, 2.0)
    seg1 = lerp(c0, c1, Nx.clip(t, 0.0, 1.0))
    seg2 = lerp(c1, c2, Nx.clip(Nx.subtract(t, 1.0), 0.0, 1.0))
    # blend aritmético (gate 0/1) evita o broadcast estrito do Nx.select
    gate = w |> Nx.greater(0.5) |> Nx.as_type(:f32)
    seg1 |> Nx.multiply(Nx.subtract(1.0, gate)) |> Nx.add(Nx.multiply(seg2, gate))
  end

  defp lerp({r0, g0, b0}, {r1, g1, b1}, w) do
    left = Nx.tensor([r0, g0, b0], type: :f32)
    right = Nx.tensor([r1, g1, b1], type: :f32)

    left |> Nx.multiply(Nx.subtract(1.0, w)) |> Nx.add(Nx.multiply(right, w))
  end

  # equivalente do np.ones((k, k), np.uint8) do protótipo (contrato §7)
  defp kernel(shape), do: Evision.Mat.from_nx(Nx.broadcast(Nx.u8(1), shape))
end
