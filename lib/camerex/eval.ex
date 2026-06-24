defmodule Camerex.Eval do
  @moduledoc """
  Helpers PUROS do harness de avaliação visual (`mix camerex.eval`): monta a tela
  de contato (grid de renders pra avaliar uma mudança em VÁRIAS fotos de uma vez,
  não numa só) e conta px por classe semântica. IO e render ficam no
  `Mix.Tasks.Camerex.Eval`; aqui é só Calc — tensor entra, tensor sai.
  """

  alias Camerex.Parser.Layers

  @doc """
  Tela de contato: empilha `tiles` `{h, w, 3}` u8 de MESMA LARGURA num grid de
  `cols` colunas. Alturas distintas são preenchidas (preto) até a maior da linha;
  tiles faltando pra fechar a última linha viram preto. Devolve um `{H, W, 3}` u8.
  """
  @spec contact_sheet([Nx.Tensor.t()], pos_integer()) :: Nx.Tensor.t()
  def contact_sheet([_ | _] = tiles, cols) when is_integer(cols) and cols > 0 do
    {_h, w, 3} = Nx.shape(hd(tiles))
    row_h = tiles |> Enum.map(&elem(Nx.shape(&1), 0)) |> Enum.max()
    black = Nx.broadcast(Nx.u8(0), {row_h, w, 3})

    padded = Enum.map(tiles, &pad_height(&1, row_h))
    rest = rem(length(padded), cols)
    filler = if rest == 0, do: [], else: List.duplicate(black, cols - rest)

    (padded ++ filler)
    |> Enum.chunk_every(cols)
    |> Enum.map(&Nx.concatenate(&1, axis: 1))
    |> Nx.concatenate(axis: 0)
  end

  defp pad_height(tile, row_h) do
    {h, _w, _} = Nx.shape(tile)

    if h >= row_h,
      do: tile,
      else: Nx.pad(tile, 0, [{0, row_h - h, 0}, {0, 0, 0}, {0, 0, 0}])
  end

  @doc "px por grupo semântico do `Layers` (pele/cabelo/roupa/…) nos `labels`."
  @spec class_counts(Nx.Tensor.t()) :: %{atom() => non_neg_integer()}
  def class_counts(labels) do
    Map.new(Layers.groups(), fn g -> {g.key, count_ids(labels, g.ids)} end)
  end

  defp count_ids(labels, ids) do
    Enum.reduce(ids, 0, fn id, acc ->
      acc + Nx.to_number(Nx.sum(Nx.equal(labels, id)))
    end)
  end
end
