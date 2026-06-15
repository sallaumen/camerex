defmodule Camerex.Neon do
  @moduledoc """
  Núcleo puro do efeito neon (contrato §4): traçado de bordas (Evision) e
  composição por máximo (Nx). Todos os tensores de imagem são RGB.
  """

  @doc """
  Bordas internas (CLAHE + bilateral + Canny dentro da máscara erodida) +
  silhueta (Canny da máscara), fechadas (CLOSE 3×3) e dilatadas (2×2).
  `(rgb u8 {h,w,3}, mask u8 {h,w}, opts)` → edges u8 `{h, w}` 0|255.

  opts: `detail:` 0..1 (default 0.5; limiar do Canny de luminância) ·
  `chroma:` 0..1 (default 0.0; Canny no canal de saturação para recuperar
  bordas de cor — ex.: tecido vermelho sobre sombra. 0 = neutro).
  """
  @spec trace_edges(Nx.Tensor.t(), Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  def trace_edges(rgb, mask, opts \\ []) do
    detail = Keyword.get(opts, :detail, 0.5)
    chroma = Keyword.get(opts, :chroma, 0.0)
    smooth = Keyword.get(opts, :smooth, false)
    canny_lo = round(100 - 80 * detail)
    canny_hi = round(220 - 160 * detail)

    {_mh, mw} = Nx.shape(mask)
    rgb_mat = Evision.Mat.from_nx_2d(rgb)
    mask_mat = Evision.Mat.from_nx(mask)
    eroded = Evision.erode(mask_mat, kernel({5, 5}))
    clahe = Evision.createCLAHE(clipLimit: 3.0, tileGridSize: {8, 8})

    gray =
      rgb_mat
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2GRAY())
      |> then(&Evision.CLAHE.apply(clahe, &1))

    inner =
      gray
      |> Evision.bilateralFilter(9, 60.0, 60.0)
      |> Evision.canny(canny_lo, canny_hi)
      |> Evision.min(eroded)

    inner
    |> Evision.max(Evision.canny(mask_mat, 50, 150))
    |> add_chroma_edges(rgb_mat, eroded, chroma)
    |> maybe_suppress_dense(smooth, mw)
    |> Evision.morphologyEx(Evision.Constant.cv_MORPH_CLOSE(), kernel({3, 3}))
    |> Evision.dilate(kernel({2, 2}))
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  # supressão por densidade: textura (sequins, padrão de tecido) faz uma região
  # de borda DENSA; contorno limpo é esparso. Onde a densidade local passa do
  # limiar, apaga — some o chuvisco/"quadrados", a silhueta e linhas isoladas
  # (densidade baixa) ficam. É o que dá o acabamento fluido tipo tubo de LED.
  @density_threshold 0.25

  defp maybe_suppress_dense(mat, false, _w), do: mat
  defp maybe_suppress_dense(mat, true, w), do: suppress_dense(mat, w)

  defp suppress_dense(edges_mat, w) do
    edges_nx = Evision.Mat.to_nx(edges_mat, Nx.BinaryBackend)

    density =
      edges_nx
      |> Nx.as_type(:f32)
      |> Nx.divide(255.0)
      |> Evision.Mat.from_nx()
      |> Evision.gaussianBlur({0, 0}, max(w / 150.0, 4.0))
      |> Evision.Mat.to_nx(Nx.BinaryBackend)

    keep = density |> Nx.less(@density_threshold) |> Nx.as_type(:u8)
    edges_nx |> Nx.multiply(keep) |> Evision.Mat.from_nx()
  end

  # chroma == 0: caminho neutro (idêntico ao traçado só-luminância de antes)
  defp add_chroma_edges(base, _rgb_mat, _eroded, chroma) when chroma <= 0.0, do: base

  # Canny no canal de saturação (HSV): pega bordas de COR que o cinza perde
  # (tecido vermelho sobre sombra). medianBlur tira sal-pimenta; despeckle
  # remove componentes minúsculos (o chuvisco de padrões finos, ex.: paetês)
  # SEM tocar nas dobras (linhas longas conectadas). O limiar acompanha `chroma`.
  defp add_chroma_edges(base, rgb_mat, eroded, chroma) do
    lo = round(72 - 80 * chroma)
    hi = round(168 - 120 * chroma)

    inner_chroma =
      rgb_mat
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2HSV())
      |> Evision.extractChannel(1)
      |> Evision.medianBlur(5)
      |> Evision.canny(lo, hi)
      |> despeckle(40)
      |> Evision.min(eroded)

    Evision.max(base, inner_chroma)
  end

  # remove componentes conectados menores que `min_area` px (speckle), mantendo
  # as linhas longas. Fundo (label 0) tem área enorme mas é 0 nas bordas → ok.
  defp despeckle(edges_mat, min_area) do
    {_n, labels, stats, _centroids} = Evision.connectedComponentsWithStats(edges_mat)
    labels_nx = Evision.Mat.to_nx(labels, Nx.BinaryBackend)
    areas = stats |> Evision.Mat.to_nx(Nx.BinaryBackend) |> then(& &1[[.., 4]])

    keep =
      areas
      |> Nx.greater_equal(min_area)
      |> Nx.take(labels_nx)
      |> Nx.multiply(255)
      |> Nx.as_type(:u8)

    edges_mat |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.min(keep) |> Evision.Mat.from_nx()
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

    # `color_field:` (campo {h,w,3} f32 pronto) sobrepõe colors/weights — é
    # como o modo cor-por-parte injeta cores já mescladas nas fronteiras.
    field = Keyword.get(opts, :color_field) || color_field(colors, weights)

    intens
    |> Nx.new_axis(-1)
    |> Nx.multiply(field)
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

  @doc """
  Campo de pesos de cor `{h, w}` (ou `nil`) para o modo do preset — **regra
  única compartilhada por foto e vídeo** para não dessincronizar (foi a falta
  do `:gradient` no vídeo que quebrou). `split_x` é o split do duotone
  (mediana na foto, EMA temporal no vídeo); ignorado em mono/gradiente.
  """
  @spec weights_for(:mono | :duotone | :gradient, Nx.Tensor.t(), number()) ::
          Nx.Tensor.t() | nil
  def weights_for(:mono, _mask, _split_x), do: nil

  def weights_for(:duotone, mask, split_x) do
    {h, w} = Nx.shape(mask)
    duotone_weights(h, w, split_x, 24)
  end

  def weights_for(:gradient, mask, _split_x) do
    {h, w} = Nx.shape(mask)
    {y_top, y_bottom} = mask_y_bounds(mask)
    vertical_weights(h, w, y_top, y_bottom)
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
