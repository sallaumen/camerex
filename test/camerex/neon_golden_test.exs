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

  @golden_teal Path.expand("exemplos/golden/casal_neon_teal.png")
  @golden_duotone Path.expand("exemplos/golden/casal_neon_duotone.png")

  defp golden_edges_f32 do
    load_gray(@golden_edges) |> Nx.as_type(:f32) |> Nx.divide(255.0)
  end

  test "compose mono reproduz casal_neon_teal.png a partir das bordas golden" do
    out = Neon.compose(golden_edges_f32(), [{43, 196, 178}], halo: 0.6)

    assert_close_to_golden(out, @golden_teal, 1.0 / 255.0, 0.0)
    assert_max_diff_le_1(out, @golden_teal)
  end

  test "compose duotone reproduz casal_neon_duotone.png" do
    mask = load_gray(@golden_mask)
    {h, w} = Nx.shape(mask)

    split = mask |> Neon.mask_median_x() |> trunc()
    weights = Neon.duotone_weights(h, w, split * 1.0, 24)

    out =
      Neon.compose(golden_edges_f32(), [{255, 138, 92}, {43, 196, 178}],
        halo: 0.6,
        duotone_weights: weights
      )

    assert_close_to_golden(out, @golden_duotone, 1.0 / 255.0, 0.0)
    assert_max_diff_le_1(out, @golden_duotone)
  end

  # critério compose do contrato §6: diff <= 1/255 POR PIXEL
  defp assert_max_diff_le_1(rgb_u8, golden_path) do
    golden =
      golden_path
      |> Evision.imread()
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)

    max_diff =
      rgb_u8
      |> Nx.as_type(:s32)
      |> Nx.subtract(Nx.as_type(golden, :s32))
      |> Nx.abs()
      |> Nx.reduce_max()
      |> Nx.to_number()

    assert max_diff <= 1,
           "diff máximo por pixel #{max_diff}/255 > 1/255 (#{golden_path})"
  end
end
