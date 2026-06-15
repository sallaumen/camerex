defmodule Camerex.Parser.LayersTest do
  use ExUnit.Case, async: true

  alias Camerex.Parser.Layers

  test "groups/0 cobre as 4 camadas com cores default" do
    keys = Enum.map(Layers.groups(), & &1.key)
    assert keys == [:skin, :hair, :clothing, :accessories]
    assert Layers.default_colors().clothing == {43, 196, 178}
  end

  test "mask/2 marca os pixels da camada (e suaviza)" do
    # bloco 8×8 de Upper-clothes (4) no centro de um campo 24×24 de fundo (0)
    rows = Nx.iota({24, 24}, axis: 0)
    cols = Nx.iota({24, 24}, axis: 1)

    bloco =
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, 8), Nx.less(rows, 16)),
        Nx.logical_and(Nx.greater_equal(cols, 8), Nx.less(cols, 16))
      )

    labels = Nx.select(bloco, 4, 0) |> Nx.as_type(:u8)

    m = Layers.mask(labels, [4, 5, 6, 7, 8, 17])
    assert Nx.shape(m) == {24, 24}
    assert Nx.to_number(m[12][12]) == 255
    assert Nx.to_number(m[0][0]) == 0
  end
end
