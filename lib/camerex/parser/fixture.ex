defmodule Camerex.Parser.Fixture do
  @moduledoc """
  Parser de teste (sem modelo): três faixas horizontais — topo cabelo (2),
  meio rosto (11), base roupa/Upper-clothes (4). Suficiente para exercitar o
  agrupamento em camadas e a coloração por parte nos testes.
  """

  @behaviour Camerex.Parser

  @impl Camerex.Parser
  def parse(rgb, _opts \\ []) do
    {h, w, 3} = Nx.shape(rgb)
    rows = Nx.iota({h, w}, axis: 0)
    third = div(h, 3)

    labels =
      Nx.less(rows, third)
      |> Nx.select(2, Nx.select(Nx.less(rows, 2 * third), 11, 4))
      |> Nx.as_type(:u8)

    {:ok, labels}
  end
end
