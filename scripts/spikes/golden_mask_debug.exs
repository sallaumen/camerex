# Instrumentação do spike 0.7 (FASE 1 do debug — só evidências, sem fix).
# Mede: (a) componentes conectados da minha máscara vs golden;
#       (b) diff raw vs golden, diff pós-largest_component vs golden;
#       (c) distribuição do diff: dentro vs fora da faixa de borda (±3px);
#       (d) sensibilidade ao limiar 30 (pixels contínuos em [20,40]).
# Rodar: mix run scripts/spikes/golden_mask_debug.exs

defmodule GoldenMaskDebug do
  @model_path Path.expand("priv/models/u2net.onnx")
  @img_path Path.expand("exemplos/entrada/casal.jpg")
  @golden_path Path.expand("exemplos/golden/casal_mask.png")

  @mean [0.485, 0.456, 0.406]
  @std [0.229, 0.224, 0.225]

  def run do
    rgb =
      @img_path
      |> Evision.imread()
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())

    {h, w, 3} = Evision.Mat.shape(rgb)

    model = Ortex.load(@model_path)
    d0 = Ortex.run(model, preprocess(rgb)) |> elem(0) |> Nx.backend_transfer()

    continuous = continuous_mask(d0, {h, w})
    mask = binarize(continuous)

    golden =
      @golden_path
      |> Evision.imread(flags: Evision.Constant.cv_IMREAD_GRAYSCALE())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)

    # (d) sensibilidade ao limiar: quantos pixels contínuos perto do 30?
    near_thr =
      Nx.logical_and(Nx.greater_equal(continuous, 20), Nx.less_equal(continuous, 40))
      |> Nx.mean()
      |> Nx.to_number()

    IO.puts("pixels contínuos em [20,40] (sensíveis ao limiar 30): #{pct(near_thr)}%")

    # (a) componentes conectados
    report_components("minha máscara (raw)", mask)
    report_components("golden", golden)

    # (b) diffs
    report_diff("raw vs golden", mask, golden)
    lc = largest_component(mask)
    report_diff("largest_component vs golden", lc, golden)

    # (c) faixa de borda da golden (±3px): o diff residual mora aí?
    band = boundary_band(golden)
    diff_bin = Nx.greater(Nx.abs(Nx.subtract(Nx.as_type(lc, :s32), Nx.as_type(golden, :s32))), 5)
    in_band = Nx.logical_and(diff_bin, band) |> Nx.sum() |> Nx.to_number()
    total_diff = Nx.sum(diff_bin) |> Nx.to_number()

    IO.puts(
      "diff (pós-lc): #{total_diff} px, na faixa de borda ±3px: #{in_band} " <>
        "(#{if total_diff > 0, do: pct(in_band / total_diff), else: 0}%)"
    )

    # dumps para inspeção visual
    Evision.imwrite("/tmp/spike_mask_raw.png", Evision.Mat.from_nx(mask))
    Evision.imwrite("/tmp/spike_mask_lc.png", Evision.Mat.from_nx(lc))
    IO.puts("masks salvas em /tmp/spike_mask_raw.png e /tmp/spike_mask_lc.png")
  end

  defp pct(x), do: Float.round(x * 100, 3)

  defp report_components(label, mask_u8) do
    {n, _labels, stats, _centroids} =
      Evision.connectedComponentsWithStats(Evision.Mat.from_nx(mask_u8), connectivity: 8)

    areas =
      if n > 1 do
        stats
        |> Evision.Mat.to_nx(Nx.BinaryBackend)
        |> Nx.slice_along_axis(1, n - 1, axis: 0)
        |> Nx.slice_along_axis(4, 1, axis: 1)
        |> Nx.to_flat_list()
        |> Enum.sort(:desc)
      else
        []
      end

    IO.puts("#{label}: #{n - 1} componente(s), áreas: #{inspect(Enum.take(areas, 8))}")
  end

  defp report_diff(label, a, b) do
    diff = Nx.abs(Nx.subtract(Nx.as_type(a, :f32), Nx.as_type(b, :f32))) |> Nx.divide(255.0)
    mean_diff = diff |> Nx.mean() |> Nx.to_number()
    frac_gt5 = diff |> Nx.greater(5.0 / 255.0) |> Nx.mean() |> Nx.to_number()

    IO.puts(
      "#{label}: diff médio #{Float.round(mean_diff * 255, 4)}/255, " <>
        "pixels > 5/255: #{pct(frac_gt5)}%"
    )
  end

  defp largest_component(mask_u8) do
    {n, labels, stats, _} =
      Evision.connectedComponentsWithStats(Evision.Mat.from_nx(mask_u8), connectivity: 8)

    if n <= 1 do
      mask_u8
    else
      areas =
        stats
        |> Evision.Mat.to_nx(Nx.BinaryBackend)
        |> Nx.slice_along_axis(1, n - 1, axis: 0)
        |> Nx.slice_along_axis(4, 1, axis: 1)
        |> Nx.squeeze(axes: [1])

      biggest = areas |> Nx.argmax() |> Nx.to_number() |> Kernel.+(1)

      labels
      |> Evision.Mat.to_nx(Nx.BinaryBackend)
      |> Nx.equal(biggest)
      |> Nx.multiply(255)
      |> Nx.as_type(:u8)
    end
  end

  # faixa de ±3px ao redor da borda da golden: dilate(7x7) != erode(7x7)
  defp boundary_band(golden_u8) do
    kernel7 = Evision.Mat.from_nx(Nx.broadcast(Nx.u8(1), {7, 7}))
    g = Evision.Mat.from_nx(golden_u8)
    dil = Evision.dilate(g, kernel7) |> Evision.Mat.to_nx(Nx.BinaryBackend)
    ero = Evision.erode(g, kernel7) |> Evision.Mat.to_nx(Nx.BinaryBackend)
    Nx.not_equal(dil, ero)
  end

  defp preprocess(rgb_mat) do
    t =
      rgb_mat
      |> Evision.resize({320, 320}, interpolation: Evision.Constant.cv_INTER_LANCZOS4())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)
      |> Nx.as_type(:f32)

    t = Nx.divide(t, Nx.max(Nx.reduce_max(t), 1.0e-6))

    t
    |> Nx.subtract(Nx.tensor(@mean))
    |> Nx.divide(Nx.tensor(@std))
    |> Nx.transpose(axes: [2, 0, 1])
    |> Nx.new_axis(0)
  end

  # mantém a máscara CONTÍNUA (antes do limiar) para análise de sensibilidade
  defp continuous_mask(d0, {h, w}) do
    pred = d0[[0, 0]]
    mn = Nx.reduce_min(pred)
    mx = Nx.reduce_max(pred)

    pred
    |> Nx.subtract(mn)
    |> Nx.divide(Nx.subtract(mx, mn))
    |> Nx.multiply(255.0)
    |> Nx.as_type(:u8)
    |> Evision.Mat.from_nx()
    |> Evision.resize({w, h}, interpolation: Evision.Constant.cv_INTER_LANCZOS4())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  defp binarize(continuous) do
    continuous |> Nx.greater(30) |> Nx.multiply(255) |> Nx.as_type(:u8)
  end
end

GoldenMaskDebug.run()
