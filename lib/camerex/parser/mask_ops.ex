defmodule Camerex.Parser.MaskOps do
  @moduledoc """
  Operações morfológicas sobre máscaras booleanas/u8 (pontes Nx ↔ Evision).
  Extraído de `Hair`/`Skin` onde estava duplicado byte-a-byte.
  """

  @spec to_mat(Nx.Tensor.t()) :: Evision.Mat.t()
  def to_mat(m), do: m |> Nx.multiply(255) |> Nx.as_type(:u8) |> Evision.Mat.from_nx()

  @spec of_mat(Evision.Mat.t()) :: Nx.Tensor.t()
  def of_mat(mat), do: mat |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.greater(0)

  @spec dilate_b(Nx.Tensor.t(), Evision.Mat.t()) :: Nx.Tensor.t()
  def dilate_b(m, k), do: of_mat(Evision.dilate(to_mat(m), k))

  @spec close_b(Nx.Tensor.t(), Evision.Mat.t()) :: Nx.Tensor.t()
  def close_b(m, k),
    do: of_mat(Evision.morphologyEx(to_mat(m), Evision.Constant.cv_MORPH_CLOSE(), k))

  @spec ellipse(non_neg_integer()) :: Evision.Mat.t()
  def ellipse(s) do
    k = max(s, 1)
    Evision.getStructuringElement(Evision.Constant.cv_MORPH_ELLIPSE(), {k, k})
  end

  @doc """
  Reconstrução geodésica (histerese): cresce a SEMENTE só dentro do CONFINAMENTO,
  iterando dilatação ∩ confinamento até estabilizar. `:div` controla o tamanho
  do kernel relativo à largura `w`; `:iters` o nº de iterações.
  """
  @spec reconstruct(Nx.Tensor.t(), Nx.Tensor.t(), pos_integer(), keyword()) :: Nx.Tensor.t()
  def reconstruct(seed, confine, w, opts \\ []) do
    iters = Keyword.get(opts, :iters, 30)
    div_ = Keyword.get(opts, :div, 55)
    k = ellipse(round(w / div_))
    Enum.reduce(1..iters, seed, fn _, acc -> Nx.logical_and(dilate_b(acc, k), confine) end)
  end

  @doc """
  Preenche buracos INTERNOS: tudo que não é fundo-conectado-à-borda. Vetorizado
  pelos bounding-boxes dos componentes do complemento. `stats` columns:
  [x, y, larg, alt, área].
  """
  @spec fill_holes(Nx.Tensor.t(), pos_integer(), pos_integer()) :: Nx.Tensor.t()
  def fill_holes(mask, h, w) do
    {n, lbls, stats, _c} =
      mask |> Nx.logical_not() |> to_mat() |> Evision.connectedComponentsWithStats()

    if n <= 1 do
      mask
    else
      st = Evision.Mat.to_nx(stats, Nx.BinaryBackend)
      {x, y, bw, bh} = {st[[.., 0]], st[[.., 1]], st[[.., 2]], st[[.., 3]]}

      touches =
        Nx.equal(x, 0)
        |> Nx.logical_or(Nx.equal(y, 0))
        |> Nx.logical_or(Nx.equal(Nx.add(x, bw), w))
        |> Nx.logical_or(Nx.equal(Nx.add(y, bh), h))

      hole =
        touches
        |> Nx.logical_not()
        |> Nx.as_type(:u8)
        |> Nx.put_slice([0], Nx.tensor([0], type: :u8))

      lbls_nx = lbls |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.as_type(:s64)
      Nx.logical_or(mask, hole |> Nx.take(lbls_nx) |> Nx.greater(0))
    end
  end
end
