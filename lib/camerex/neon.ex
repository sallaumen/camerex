defmodule Camerex.Neon do
  @moduledoc """
  Núcleo puro do efeito neon (contrato §4): traçado de bordas (Evision) e
  composição por máximo (Nx). Todos os tensores de imagem são RGB.
  """

  @doc """
  Bordas internas (CLAHE + bilateral + Canny dentro da máscara erodida) +
  silhueta (Canny da máscara), fechadas (CLOSE 3×3) e dilatadas (2×2).
  `(rgb u8 {h,w,3}, mask u8 {h,w}, detail: 0.0..1.0 default 0.5)` →
  edges u8 `{h, w}` 0|255.
  """
  @spec trace_edges(Nx.Tensor.t(), Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  def trace_edges(rgb, mask, opts \\ []) do
    detail = Keyword.get(opts, :detail, 0.5)
    canny_lo = round(100 - 80 * detail)
    canny_hi = round(220 - 160 * detail)

    rgb_mat = Evision.Mat.from_nx_2d(rgb)
    mask_mat = Evision.Mat.from_nx(mask)
    clahe = Evision.createCLAHE(clipLimit: 3.0, tileGridSize: {8, 8})

    gray =
      rgb_mat
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2GRAY())
      |> then(&Evision.CLAHE.apply(clahe, &1))

    inner =
      gray
      |> Evision.bilateralFilter(9, 60.0, 60.0)
      |> Evision.canny(canny_lo, canny_hi)
      |> Evision.min(Evision.erode(mask_mat, kernel({5, 5})))

    inner
    |> Evision.max(Evision.canny(mask_mat, 50, 150))
    |> Evision.morphologyEx(Evision.Constant.cv_MORPH_CLOSE(), kernel({3, 3}))
    |> Evision.dilate(kernel({2, 2}))
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  # equivalente do np.ones((k, k), np.uint8) do protótipo (contrato §7)
  defp kernel(shape), do: Evision.Mat.from_nx(Nx.broadcast(Nx.u8(1), shape))
end
