# Spike 0.7: nosso pré/pós U2Net (contrato §4) reproduz a máscara da rembg?
# Critério (contrato §6): diff médio < 1/255 E <= 1% dos pixels com diff > 5/255.
# Rodar: mix run scripts/spikes/golden_mask.exs

defmodule GoldenMaskSpike do
  @model_path Path.expand("priv/models/u2net.onnx")
  @img_path Path.expand("exemplos/entrada/casal.jpg")
  @golden_path Path.expand("exemplos/golden/casal_mask.png")

  # normalização ImageNet usada pela rembg (contrato §4)
  @mean [0.485, 0.456, 0.406]
  @std [0.229, 0.224, 0.225]

  def run do
    for {label, path} <- [model: @model_path, imagem: @img_path, golden: @golden_path],
        not File.exists?(path) do
      IO.puts("FAIL: #{label} ausente: #{path}")
      System.halt(1)
    end

    # imread devolve BGR; o domínio inteiro trabalha em RGB (contrato §4)
    rgb =
      @img_path
      |> Evision.imread()
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())

    {h, w, 3} = Evision.Mat.shape(rgb)

    model = Ortex.load(@model_path)
    d0 = Ortex.run(model, preprocess(rgb)) |> elem(0) |> Nx.backend_transfer()
    mask = postprocess(d0, {h, w})

    golden =
      @golden_path
      |> Evision.imread(flags: Evision.Constant.cv_IMREAD_GRAYSCALE())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)

    diff =
      Nx.abs(Nx.subtract(Nx.as_type(mask, :f32), Nx.as_type(golden, :f32)))
      |> Nx.divide(255.0)

    mean_diff = diff |> Nx.mean() |> Nx.to_number()
    frac_gt5 = diff |> Nx.greater(5.0 / 255.0) |> Nx.mean() |> Nx.to_number()

    IO.puts("diff médio: #{Float.round(mean_diff * 255, 4)}/255 (limite: < 1/255)")
    IO.puts("pixels com diff > 5/255: #{Float.round(frac_gt5 * 100, 3)}% (limite: <= 1%)")

    if mean_diff < 1.0 / 255.0 and frac_gt5 <= 0.01 do
      IO.puts("PASS")
    else
      IO.puts("FAIL")
      System.halt(1)
    end
  end

  # {h,w,3} u8 RGB -> {1,3,320,320} f32 (vira Camerex.Segmenter.U2Net.preprocess/1)
  # INTER_AREA no downscale: o resize por interpolação do OpenCV (LANCZOS4/LINEAR)
  # não faz anti-aliasing e o aliasing desloca a predição do U²-Net (debug 0.7);
  # INTER_AREA reproduz o LANCZOS anti-aliased do PIL dentro da tolerância.
  defp preprocess(rgb_mat) do
    t =
      rgb_mat
      |> Evision.resize({320, 320}, interpolation: Evision.Constant.cv_INTER_AREA())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)
      |> Nx.as_type(:f32)

    t = Nx.divide(t, Nx.max(Nx.reduce_max(t), 1.0e-6))

    t
    |> Nx.subtract(Nx.tensor(@mean))
    |> Nx.divide(Nx.tensor(@std))
    |> Nx.transpose(axes: [2, 0, 1])
    |> Nx.new_axis(0)
  end

  # {1,1,320,320} f32 -> máscara {h,w} u8 0|255 (vira U2Net.postprocess/2 + limiar)
  defp postprocess(d0, {h, w}) do
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
    |> Nx.greater(30)
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
  end
end

GoldenMaskSpike.run()
