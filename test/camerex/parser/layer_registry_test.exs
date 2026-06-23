defmodule Camerex.Parser.LayerRegistryTest do
  use ExUnit.Case, async: true
  alias Camerex.Parser.LayerRegistry

  test "all/0 devolve as 4 camadas atuais" do
    ids = LayerRegistry.all() |> Enum.map(& &1.id)
    assert :object in ids
    assert :hair in ids
    assert :apparatus in ids
    assert :skin in ids
  end

  test "ordenadas: baseline antes de overlay antes de destructive" do
    bands = LayerRegistry.all() |> Enum.map(& &1.order_band)
    rank = %{baseline: 0, overlay: 1, destructive: 2}
    assert bands == Enum.sort_by(bands, &Map.fetch!(rank, &1))
  end

  test "fetch/1 aceita atom e string; ignora desconhecido" do
    assert %{id: :hair} = LayerRegistry.fetch(:hair)
    assert %{id: :hair} = LayerRegistry.fetch("hair")
    assert LayerRegistry.fetch(:naoexiste) == nil
    assert LayerRegistry.fetch("naoexiste") == nil
  end

  test "active/1 lê o param :bool do spec (não detect_<id>)" do
    on = %{"detect_hair" => true, "detect_object" => false}
    ids = LayerRegistry.active(on) |> Enum.map(& &1.id)
    assert :hair in ids
    refute :object in ids
    refute :skin in ids
  end

  test "active/1: apparatus ativa via detect_aerial (id≠prefixo do param)" do
    ids = LayerRegistry.active(%{"detect_aerial" => true}) |> Enum.map(& &1.id)
    assert :apparatus in ids
    # detect_apparatus NÃO existe — não deve ativar nada
    assert LayerRegistry.active(%{"detect_apparatus" => true}) == []
  end

  test "required_segmentations/1 devolve MapSet de {model, kind} das ativas" do
    specs = Enum.filter(LayerRegistry.all(), &(&1.id in [:object, :apparatus]))
    req = LayerRegistry.required_segmentations(specs)
    assert MapSet.equal?(req, MapSet.new([{"u2net", :largest}, {"u2netp", :full}]))
  end

  test "param_keys/0 contém os params confirmados das 4 camadas" do
    keys = LayerRegistry.param_keys()
    assert "detect_skin" in keys
    assert "skin_sensitivity" in keys
    assert "detect_hair" in keys
    assert "hair_color" in keys
    assert "hair_model" in keys
    assert "detect_aerial" in keys
    assert "detect_object" in keys
  end

  test "ui_specs/0 não vaza :module nem captures" do
    LayerRegistry.ui_specs()
    |> Enum.each(fn s -> refute Map.has_key?(s, :module) end)
  end
end
