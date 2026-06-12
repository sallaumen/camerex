defmodule Camerex.GoldenHelpersTest do
  use ExUnit.Case, async: true

  import Camerex.GoldenHelpers

  @moduletag :golden

  @golden_mask Path.expand("exemplos/golden/casal_mask.png")

  defp golden_tensor do
    @golden_mask
    |> Evision.imread(flags: Evision.Constant.cv_IMREAD_GRAYSCALE())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  test "tensor idêntico ao golden passa (diff zero)" do
    assert_close_to_golden(golden_tensor(), @golden_mask, 1.0 / 255.0, 0.01)
  end

  test "tensor invertido falha no critério" do
    inverted = Nx.subtract(255, golden_tensor())

    assert_raise ExUnit.AssertionError, fn ->
      assert_close_to_golden(inverted, @golden_mask, 1.0 / 255.0, 0.01)
    end
  end
end
