defmodule Camerex.Parser.LayersTest do
  use ExUnit.Case, async: true

  alias Camerex.Parser.Layers

  test "groups/0 cobre as camadas com cores default; boné separado do cabelo" do
    keys = Enum.map(Layers.groups(), & &1.key)
    assert keys == [:skin, :hair, :hat, :clothing, :accessories, :object]
    assert Layers.default_colors().clothing == {43, 196, 178}

    # Hat (classe 1) só no grupo do boné; cabelo é só a classe 2
    hat = Enum.find(Layers.groups(), &(&1.key == :hat))
    hair = Enum.find(Layers.groups(), &(&1.key == :hair))
    assert hat.ids == [1]
    assert hair.ids == [2]

    # objeto na mão é a classe virtual 18 (injetada pelo Parser.Object)
    object = Enum.find(Layers.groups(), &(&1.key == :object))
    assert object.ids == [18]
  end

  test "suggest_colors/2 detecta a cor da parte (vermelho na roupa) e realça" do
    # roupa (label 4) vermelha no topo; resto fundo (0). cabelo ausente → default
    rows = Nx.iota({40, 40}, axis: 0)
    cloth = Nx.less(rows, 20)
    labels = Nx.select(cloth, 4, 0) |> Nx.as_type(:u8)

    red = Nx.tensor([200, 20, 20], type: :u8) |> Nx.broadcast({40, 40, 3})

    rgb =
      Nx.select(
        Nx.new_axis(cloth, -1) |> Nx.broadcast({40, 40, 3}),
        red,
        Nx.broadcast(Nx.u8(10), {40, 40, 3})
      )

    colors = Layers.suggest_colors(rgb, labels)

    {r, g, b} = colors.clothing
    assert r > g and r > b, "roupa deveria puxar p/ vermelho, veio #{inspect(colors.clothing)}"
    # cabelo ausente na imagem → mantém o default
    assert colors.hair == Layers.default_colors().hair
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
