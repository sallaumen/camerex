defmodule Camerex.GoldenHelpers do
  @moduledoc """
  Comparação de tensores com golden files PNG gerados pelo protótipo Python
  (`python/gen_goldens.py`). Critério do contrato §6.
  """

  import ExUnit.Assertions

  @doc """
  Compara `tensor` u8 (`{h, w}` grayscale ou `{h, w, 3}` RGB) com o PNG em
  `golden_path`. Passa se diff médio < `mean_tol` E fração de pixels com
  diff > 5/255 <= `frac_gt5_tol` (diffs normalizados para [0, 1]).
  """
  def assert_close_to_golden(tensor, golden_path, mean_tol, frac_gt5_tol) do
    golden = load_golden(golden_path, Nx.rank(tensor))

    assert Nx.shape(tensor) == Nx.shape(golden),
           "shape #{inspect(Nx.shape(tensor))} difere do golden " <>
             "#{inspect(Nx.shape(golden))} (#{golden_path})"

    diff =
      tensor
      |> Nx.as_type(:f32)
      |> Nx.subtract(Nx.as_type(golden, :f32))
      |> Nx.abs()
      |> Nx.divide(255.0)

    mean_diff = diff |> Nx.mean() |> Nx.to_number()
    frac_gt5 = diff |> Nx.greater(5.0 / 255.0) |> Nx.mean() |> Nx.to_number()

    assert mean_diff < mean_tol,
           "diff médio #{Float.round(mean_diff * 255, 4)}/255 não é < " <>
             "#{Float.round(mean_tol * 255, 4)}/255 (#{golden_path})"

    assert frac_gt5 <= frac_gt5_tol,
           "#{Float.round(frac_gt5 * 100, 3)}% dos pixels com diff > 5/255 " <>
             "(limite #{Float.round(frac_gt5_tol * 100, 3)}%) (#{golden_path})"
  end

  defp load_golden(path, 2) do
    path
    |> Evision.imread(flags: Evision.Constant.cv_IMREAD_GRAYSCALE())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  defp load_golden(path, 3) do
    path
    |> Evision.imread()
    |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end
end
