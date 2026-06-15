defmodule Camerex.ParserTest do
  use ExUnit.Case, async: true

  alias Camerex.Parser

  test "Fixture rotula faixas: cabelo no topo, rosto no meio, roupa na base" do
    rgb = Nx.broadcast(Nx.u8(120), {30, 10, 3})

    assert {:ok, labels} = Parser.parse(rgb)
    assert Nx.shape(labels) == {30, 10}
    assert Nx.type(labels) == {:u, 8}

    assert Nx.to_number(labels[2][0]) == 2
    assert Nx.to_number(labels[15][0]) == 11
    assert Nx.to_number(labels[28][0]) == 4
  end
end
