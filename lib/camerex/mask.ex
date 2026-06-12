defmodule Camerex.Mask do
  @moduledoc """
  Operações sobre máscaras binárias `{h, w}` u8 0|255: componentes
  conectados (Evision) e suavização temporal EMA (Nx).
  """

  @area_col 4

  @doc "Mantém só o maior componente conectado (descarta blobs espúrios)."
  @spec largest_component(Nx.Tensor.t()) :: Nx.Tensor.t()
  def largest_component(mask) do
    {n, labels, stats} = components(mask)

    if n <= 1 do
      mask
    else
      # stats[0] é o fundo; argmax nas áreas dos labels 1..n-1
      areas = stats[[1..(n - 1), @area_col]]
      biggest = 1 + (areas |> Nx.argmax() |> Nx.to_number())
      binarize_label(labels, biggest)
    end
  end

  @doc """
  Componente com maior sobreposição com a máscara anterior (evita o sujeito
  "pular" para outra pessoa entre frames). Score = overlap + 1.0e-4 * área;
  sem anterior, delega para `largest_component/1` (contrato §4).
  """
  @spec consistent_component(Nx.Tensor.t(), Nx.Tensor.t() | nil) :: Nx.Tensor.t()
  def consistent_component(mask, nil), do: largest_component(mask)

  def consistent_component(mask, prev) do
    {n, labels, stats} = components(mask)

    if n <= 1 do
      mask
    else
      prev_bin = Nx.greater(prev, 0)

      best =
        Enum.max_by(1..(n - 1), fn i ->
          overlap =
            labels
            |> Nx.equal(i)
            |> Nx.logical_and(prev_bin)
            |> Nx.sum()
            |> Nx.to_number()

          overlap + 1.0e-4 * Nx.to_number(stats[[i, @area_col]])
        end)

      binarize_label(labels, best)
    end
  end

  @doc """
  Média móvel exponencial de máscaras f32 `{h, w}` em [0, 1]; `alpha` é o
  peso do frame ANTERIOR (default 0.45, contrato §4). `prev` nil → `curr`.
  """
  @spec ema(Nx.Tensor.t(), Nx.Tensor.t() | nil, float()) :: Nx.Tensor.t()
  def ema(curr, prev, alpha \\ 0.45)

  def ema(curr, nil, _alpha), do: curr

  def ema(curr, prev, alpha) do
    prev |> Nx.multiply(alpha) |> Nx.add(Nx.multiply(curr, 1.0 - alpha))
  end

  defp components(mask) do
    {n, labels_mat, stats_mat, _centroids} =
      mask
      |> Evision.Mat.from_nx()
      |> Evision.connectedComponentsWithStats()

    {n, Evision.Mat.to_nx(labels_mat, Nx.BinaryBackend),
     Evision.Mat.to_nx(stats_mat, Nx.BinaryBackend)}
  end

  defp binarize_label(labels, label) do
    labels |> Nx.equal(label) |> Nx.multiply(255) |> Nx.as_type(:u8)
  end
end
