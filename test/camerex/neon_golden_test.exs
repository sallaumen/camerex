defmodule Camerex.NeonGoldenTest do
  use ExUnit.Case, async: true

  import Camerex.GoldenHelpers

  alias Camerex.Neon

  @moduletag :golden

  @casal Path.expand("exemplos/entrada/casal.jpg")
  @golden_mask Path.expand("exemplos/golden/casal_mask.png")
  @golden_edges Path.expand("exemplos/golden/casal_edges.png")

  defp load_rgb(path) do
    path
    |> Evision.imread()
    |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  defp load_gray(path) do
    path
    |> Evision.imread(flags: Evision.Constant.cv_IMREAD_GRAYSCALE())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  test "trace_edges reproduz casal_edges.png a partir da máscara golden" do
    edges = Neon.trace_edges(load_rgb(@casal), load_gray(@golden_mask))

    # critério "ops OpenCV" (contrato §6): diff médio < 1/255. Bordas são
    # binárias, então a média já limita a fração de pixels divergentes.
    assert_close_to_golden(edges, @golden_edges, 1.0 / 255.0, 0.01)
  end
end
