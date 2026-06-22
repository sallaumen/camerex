defmodule Camerex.ColorJSONTest do
  use ExUnit.Case, async: true

  alias Camerex.ColorJSON
  alias Camerex.Parser.Layers

  # uma chave de grupo real, derivada dos grupos (robusto a mudanças de nomes)
  @key Layers.groups() |> hd() |> Map.fetch!(:key)

  test "to_json produz um objeto com todas as chaves dos grupos" do
    json = ColorJSON.to_json(%{})
    assert json =~ "{"

    for %{key: key} <- Layers.groups() do
      assert json =~ ~s("#{key}":)
    end
  end

  test "round-trip: to_json |> parse devolve exatamente os defaults" do
    {:ok, parsed} = %{} |> ColorJSON.to_json() |> ColorJSON.parse()
    assert parsed == Layers.default_colors()
  end

  test "parse aceita hex e mescla sobre os defaults" do
    {:ok, colors} = ColorJSON.parse(~s({"#{@key}": "#2BC4B2"}))
    assert colors[@key] == {0x2B, 0xC4, 0xB2}
  end

  test "parse aceita [r, g, b]" do
    {:ok, colors} = ColorJSON.parse(~s({"#{@key}": [10, 20, 30]}))
    assert colors[@key] == {10, 20, 30}
  end

  test "parse ignora chaves desconhecidas (mantém defaults)" do
    {:ok, colors} = ColorJSON.parse(~s({"chave_que_nao_existe": "#FFFFFF"}))
    assert colors == Layers.default_colors()
  end

  test "parse rejeita cor malformada com erro legível" do
    assert {:error, msg} = ColorJSON.parse(~s({"#{@key}": "vermelho"}))
    assert msg =~ "cor inválida"
  end

  test "parse rejeita [r,g,b] fora de 0..255" do
    assert {:error, _} = ColorJSON.parse(~s({"#{@key}": [10, 20, 999]}))
  end

  test "parse rejeita JSON que não é objeto" do
    assert {:error, _} = ColorJSON.parse("[1, 2, 3]")
  end

  test "parse rejeita JSON inválido" do
    assert {:error, msg} = ColorJSON.parse("{nao é json")
    assert msg =~ "inválido"
  end
end
