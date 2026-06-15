defmodule Camerex.Neon.Scene do
  @moduledoc """
  Poça de luz no chão sob os pés — não um reflexo de espelho/água, mas um
  brilho **esfumaçado** que ecoa as cores dos pés, como se a luz saísse do
  casal e iluminasse o chão ao redor de onde pisam.

  Acha os pés pela base da silhueta acesa (funciona em mono/duotone/gradiente/
  camadas, pois deriva do próprio neon composto), pega a cor média da faixa dos
  pés e desenha uma **elipse radial difusa** (perspectiva de chão) centrada no
  nível do pé — o casal fica no MEIO da elipse, metade abrindo atrás das pernas,
  metade à frente no chão. Estende a imagem só o tanto da metade de baixo da
  elipse. Puro (Nx/Evision).
  """

  @bright_threshold 40
  # raios da elipse relativos à largura da figura (rx) e achatamento de
  # perspectiva (ry); a faixa dos pés é a fração de baixo da silhueta de onde
  # saem o centro horizontal e a cor do brilho.
  @rx_frac 0.55
  @ry_ratio 0.32
  @feet_band_frac 0.12

  @doc """
  Recebe o neon RGB u8 `{h, w, 3}` e devolve uma imagem mais alta com o brilho
  do chão sob os pés. Sem nada aceso, devolve o neon intacto.

  opts: `glow:` 0..1 (intensidade do brilho, default 0.85) ·
  `spread:` 0..1 (espalhamento/tamanho da poça, default 0.5).
  """
  @spec apply(Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  def apply(neon, opts \\ []) do
    glow = Keyword.get(opts, :glow, 0.85)
    spread = Keyword.get(opts, :spread, 0.5)

    {h, w, _} = Nx.shape(neon)
    bright = neon |> Nx.sum(axes: [-1]) |> Nx.greater(@bright_threshold)

    case figure_bounds(bright, h, w) do
      nil -> neon
      bounds -> glow_pool(neon, bright, bounds, glow, spread)
    end
  end

  defp glow_pool(neon, bright, {_top, ground, left, right} = bounds, glow, spread) do
    {h, w, _} = Nx.shape(neon)
    fig_w = max(right - left, 1)

    {cx, feet_color} = feet_anchor(neon, bright, bounds)

    # espalhamento 0..1 → multiplicador de tamanho [0.6, 1.8]
    rx = fig_w * @rx_frac * (0.6 + 1.2 * spread)
    ry = rx * @ry_ratio
    pad = max(round(ry), 1)

    canvas = Nx.concatenate([Nx.as_type(neon, :f32), Nx.broadcast(0.0, {pad, w, 3})], axis: 0)

    intensity = ellipse_intensity(h + pad, w, cx, ground, rx, ry, glow)
    glow_rgb = Nx.multiply(Nx.new_axis(intensity, -1), Nx.reshape(feet_color, {1, 1, 3}))

    # figura por cima (crispa); o brilho preenche o escuro ao redor/embaixo
    canvas |> Nx.max(glow_rgb) |> Nx.clip(0, 255) |> Nx.as_type(:u8)
  end

  # centro horizontal e cor média da FAIXA DOS PÉS (fração de baixo da silhueta)
  defp feet_anchor(neon, bright, {top, ground, _left, _right}) do
    {_h, w, _} = Nx.shape(neon)
    fig_h = max(ground - top, 1)
    start = max(ground - round(fig_h * @feet_band_frac), 0)
    len = ground - start + 1

    band = Nx.slice_along_axis(bright, start, len, axis: 0)
    band_neon = neon |> Nx.slice_along_axis(start, len, axis: 0) |> Nx.as_type(:f32)
    cnt = max(Nx.to_number(Nx.sum(band)), 1)

    cols = band |> Nx.any(axes: [0]) |> Nx.as_type(:f32)
    cx = weighted_center(cols, w)

    color =
      band_neon |> Nx.multiply(Nx.new_axis(band, -1)) |> Nx.sum(axes: [0, 1]) |> Nx.divide(cnt)

    {cx, color}
  end

  defp weighted_center(cols, w) do
    total = Nx.to_number(Nx.sum(cols))

    if total == 0 do
      w / 2
    else
      idx = Nx.iota({w}) |> Nx.as_type(:f32)
      Nx.to_number(Nx.divide(Nx.sum(Nx.multiply(idx, cols)), total))
    end
  end

  # campo radial elíptico (1 no centro → 0 na borda), suavizado e esfumaçado
  defp ellipse_intensity(ch, w, cx, cy, rx, ry, glow) do
    fr = Nx.iota({ch, w}, axis: 0) |> Nx.as_type(:f32)
    fc = Nx.iota({ch, w}, axis: 1) |> Nx.as_type(:f32)

    dist =
      Nx.add(
        Nx.pow(Nx.divide(Nx.subtract(fc, cx), rx), 2),
        Nx.pow(Nx.divide(Nx.subtract(fr, cy), ry), 2)
      )

    dist
    |> then(&Nx.subtract(1.0, &1))
    |> Nx.max(0.0)
    |> Nx.pow(1.5)
    |> Nx.multiply(glow)
    |> blur(max(w / 45.0, 6.0))
  end

  defp blur(t, sigma) do
    t
    |> Evision.Mat.from_nx()
    |> Evision.gaussianBlur({0, 0}, sigma)
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  # {top, ground, left, right} dos pixels acesos; nil se nada aceso
  defp figure_bounds(bright, h, w) do
    rows = Nx.any(bright, axes: [1])

    if Nx.to_number(Nx.sum(rows)) == 0 do
      nil
    else
      ridx = Nx.iota({h})
      top = rows |> Nx.select(ridx, h) |> Nx.reduce_min() |> Nx.to_number()
      ground = rows |> Nx.select(ridx, -1) |> Nx.reduce_max() |> Nx.to_number()

      cols = Nx.any(bright, axes: [0])
      cidx = Nx.iota({w})
      left = cols |> Nx.select(cidx, w) |> Nx.reduce_min() |> Nx.to_number()
      right = cols |> Nx.select(cidx, -1) |> Nx.reduce_max() |> Nx.to_number()

      {top, ground, left, right}
    end
  end
end
