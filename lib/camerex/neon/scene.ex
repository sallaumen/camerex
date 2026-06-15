defmodule Camerex.Neon.Scene do
  @moduledoc """
  Chão com reflexo de água e poça de luz, anexado abaixo do sujeito. Deriva
  tudo do próprio neon composto (linha do chão = base dos pixels acesos), então
  funciona igual em mono/duotone/gradiente/camadas. Anexar o piso ainda elimina
  o espaço vazio sob os pés (o "voando"). Puro (Nx/Evision).
  """

  @bright_threshold 40

  @doc """
  Recebe o neon RGB u8 `{h, w, 3}` e devolve uma imagem **mais alta**
  `{ground_y + floor_h, w, 3}` com o sujeito no topo e o piso embaixo.

  opts: `reflection:` 0..1 (força do reflexo, default 0.55) · `ripple:` 0..1
  (ondulação, default 0.35) · `pool:` 0..1 (poça de luz, default 0.7) ·
  `floor_height:` fração da altura do sujeito (default 0.5).
  """
  @spec apply(Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  def apply(neon, opts \\ []) do
    reflection = Keyword.get(opts, :reflection, 0.55)
    ripple = Keyword.get(opts, :ripple, 0.35)
    pool = Keyword.get(opts, :pool, 0.7)
    floor_frac = Keyword.get(opts, :floor_height, 0.5)

    {h, w, _} = Nx.shape(neon)
    bright = neon |> Nx.sum(axes: [-1]) |> Nx.greater(@bright_threshold)
    {top, ground} = vertical_bounds(bright, h)
    floor_h = max(round((ground - top) * floor_frac), 8)

    subject = Nx.slice_along_axis(neon, 0, ground + 1, axis: 0)
    floor = build_floor(neon, bright, ground, floor_h, w, reflection, ripple, pool)

    Nx.concatenate([subject, floor], axis: 0)
  end

  defp build_floor(neon, bright, ground, floor_h, w, reflection, ripple, pool) do
    refl = reflection_band(neon, ground, floor_h, w, reflection, ripple)
    pool_rgb = pool_glow(neon, bright, ground, floor_h, w, pool)

    refl |> Nx.max(pool_rgb) |> Nx.clip(0, 255) |> Nx.as_type(:u8)
  end

  # espelha a faixa logo acima do chão, esmaece para baixo, ondula e borra
  defp reflection_band(neon, ground, floor_h, w, reflection, ripple) do
    start = max(ground - floor_h + 1, 0)
    len = min(floor_h, ground - start + 1)

    refl =
      neon
      |> Nx.slice_along_axis(start, len, axis: 0)
      |> Nx.reverse(axes: [0])
      |> Nx.as_type(:f32)
      |> pad_rows(floor_h)

    ramp =
      Nx.iota({floor_h})
      |> Nx.as_type(:f32)
      |> Nx.divide(floor_h)
      |> then(&Nx.subtract(1.0, &1))
      |> Nx.multiply(reflection)

    refl
    |> Nx.multiply(Nx.reshape(ramp, {floor_h, 1, 1}))
    |> ripple_and_blur(floor_h, w, ripple)
  end

  defp ripple_and_blur(refl, floor_h, w, ripple) do
    rr = Nx.iota({floor_h}) |> Nx.as_type(:f32)
    wavelength = max(floor_h / 2.5, 4.0)

    disp =
      rr
      |> Nx.divide(floor_h)
      |> Nx.multiply(ripple * 10.0)
      |> Nx.multiply(Nx.sin(Nx.multiply(rr, 6.28318 / wavelength)))

    map_x =
      Nx.iota({floor_h, w}, axis: 1)
      |> Nx.as_type(:f32)
      |> Nx.subtract(Nx.reshape(disp, {floor_h, 1}))

    map_y = Nx.iota({floor_h, w}, axis: 0) |> Nx.as_type(:f32)

    refl
    |> Nx.clip(0, 255)
    |> Nx.as_type(:u8)
    |> Evision.Mat.from_nx_2d()
    |> Evision.remap(
      Evision.Mat.from_nx(map_x),
      Evision.Mat.from_nx(map_y),
      Evision.Constant.cv_INTER_LINEAR()
    )
    |> Evision.gaussianBlur({0, 0}, 1.6)
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.as_type(:f32)
  end

  # poça elíptica radial na cor média dos pixels acesos, centrada nos pés
  defp pool_glow(neon, bright, ground, floor_h, w, pool) do
    cnt = max(Nx.to_number(Nx.sum(bright)), 1)

    glow =
      neon
      |> Nx.as_type(:f32)
      |> Nx.multiply(Nx.new_axis(bright, -1))
      |> Nx.sum(axes: [0, 1])
      |> Nx.divide(cnt)

    cx = ground_center_x(bright, ground, floor_h, w)
    fr = Nx.iota({floor_h, w}, axis: 0) |> Nx.as_type(:f32)
    fc = Nx.iota({floor_h, w}, axis: 1) |> Nx.as_type(:f32)

    dist =
      Nx.add(
        Nx.pow(Nx.divide(Nx.subtract(fc, cx), w * 0.28), 2),
        Nx.pow(Nx.divide(fr, floor_h * 0.7), 2)
      )

    intensity = dist |> then(&Nx.subtract(1.0, &1)) |> Nx.max(0.0) |> Nx.multiply(pool)
    Nx.multiply(Nx.new_axis(intensity, -1), Nx.reshape(glow, {1, 1, 3}))
  end

  defp vertical_bounds(bright, h) do
    rows = Nx.any(bright, axes: [1])

    if Nx.to_number(Nx.sum(rows)) == 0 do
      {0, h - 1}
    else
      idx = Nx.iota({h})

      {rows |> Nx.select(idx, h) |> Nx.reduce_min() |> Nx.to_number(),
       rows |> Nx.select(idx, -1) |> Nx.reduce_max() |> Nx.to_number()}
    end
  end

  defp ground_center_x(bright, ground, floor_h, w) do
    start = max(ground - floor_h, 0)
    len = max(min(floor_h, ground - start), 1)

    cols_on =
      bright |> Nx.slice_along_axis(start, len, axis: 0) |> Nx.any(axes: [0]) |> Nx.as_type(:f32)

    if Nx.to_number(Nx.sum(cols_on)) == 0 do
      div(w, 2)
    else
      idx = Nx.iota({w}) |> Nx.as_type(:f32)
      Nx.to_number(Nx.divide(Nx.sum(Nx.multiply(idx, cols_on)), Nx.sum(cols_on)))
    end
  end

  # garante {floor_h, w, 3} mesmo quando a faixa de origem é menor que o piso
  defp pad_rows(t, floor_h) do
    {rows, w, c} = Nx.shape(t)

    if rows >= floor_h do
      Nx.slice_along_axis(t, 0, floor_h, axis: 0)
    else
      Nx.concatenate([t, Nx.broadcast(0.0, {floor_h - rows, w, c})], axis: 0)
    end
  end
end
