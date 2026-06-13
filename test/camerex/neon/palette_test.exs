defmodule Camerex.Neon.PaletteTest do
  use ExUnit.Case, async: true

  alias Camerex.Neon.Palette

  test "all/0 devolve os presets na ordem, com os ids do contrato + gradientes" do
    assert Enum.map(Palette.all(), & &1.id) ==
             ~w(forro-laranja forro-teal forro-duotone pulp miami ouro aurora brasa)
  end

  test "cores RGB exatas do contrato §4" do
    assert Palette.get("forro-laranja").colors == [{255, 138, 92}]
    assert Palette.get("forro-teal").colors == [{43, 196, 178}]
    assert Palette.get("forro-duotone").colors == [{255, 138, 92}, {43, 196, 178}]
    assert Palette.get("pulp").colors == [{177, 74, 237}, {74, 155, 237}]
    assert Palette.get("miami").colors == [{255, 46, 151}, {0, 194, 255}]
    assert Palette.get("ouro").colors == [{255, 209, 102}]
  end

  test "mono tem 1 cor; duotone tem 2; gradiente tem 2 ou 3" do
    for preset <- Palette.all() do
      case preset.mode do
        :mono -> assert length(preset.colors) == 1
        :duotone -> assert length(preset.colors) == 2
        :gradient -> assert length(preset.colors) in 2..3
      end
    end
  end

  describe "presets de gradiente" do
    test "aurora é gradiente de 3 paradas" do
      assert %{mode: :gradient, colors: colors} = Palette.get("aurora")
      assert length(colors) == 3
    end

    test "brasa é gradiente de 2 paradas" do
      assert %{mode: :gradient, colors: [_, _]} = Palette.get("brasa")
    end
  end

  test "get/1 com id desconhecido devolve nil" do
    assert Palette.get("vaporwave") == nil
  end

  describe "hex/1" do
    test "converte cor RGB para hex CSS" do
      assert Palette.hex({255, 138, 92}) == "#FF8A5C"
      assert Palette.hex({0, 194, 255}) == "#00C2FF"
      assert Palette.hex({43, 196, 178}) == "#2BC4B2"
    end
  end
end
