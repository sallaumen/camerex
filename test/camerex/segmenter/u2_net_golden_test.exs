defmodule Camerex.Segmenter.U2NetGoldenTest do
  use ExUnit.Case, async: false

  import Camerex.GoldenHelpers

  alias Camerex.Segmenter.U2Net

  @moduletag :model
  @moduletag :golden

  @img_path Path.expand("exemplos/entrada/casal.jpg")
  @golden_path Path.expand("exemplos/golden/casal_mask.png")
  @model_path Path.expand("priv/models/u2net.onnx")

  test "máscara do casal reproduz o golden da rembg (contrato §6)" do
    rgb =
      @img_path
      |> Evision.imread()
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)

    {h, w, 3} = Nx.shape(rgb)

    model = Ortex.load(@model_path)

    d0 =
      model
      |> Ortex.run(U2Net.preprocess(rgb))
      |> elem(0)
      |> Nx.backend_transfer()

    mask = d0 |> U2Net.postprocess({h, w}) |> U2Net.binarize()

    # critério de máscara (contrato §6): média < 1/255 e <= 1% acima de 5/255
    assert_close_to_golden(mask, @golden_path, 1.0 / 255.0, 0.01)
  end
end
