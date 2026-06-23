defmodule Camerex.RenderParamsSymmetryTest do
  @moduledoc """
  Rede de segurança PERMANENTE do refactor de camadas: garante que TODO param
  declarado no `LayerRegistry` existe no `RenderParams` (struct + manifest) e que
  `Library.param_keys/0` deriva do mesmo catálogo. É o teste que impede o próximo
  bug-Skin (camada backend-completa porém inalcançável pela UI por faltar nas 6
  fontes-da-verdade que existiam à mão).
  """
  use ExUnit.Case, async: true

  alias Camerex.{Library, RenderParams}
  alias Camerex.Parser.LayerRegistry

  test "TODO param do catálogo está no defstruct do RenderParams" do
    spec_keys = LayerRegistry.param_keys() |> MapSet.new()

    struct_keys =
      RenderParams.default()
      |> Map.from_struct()
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    missing = MapSet.difference(spec_keys, struct_keys)
    assert MapSet.size(missing) == 0, "faltam no defstruct: #{inspect(MapSet.to_list(missing))}"
  end

  test "TODO param do catálogo aparece em to_manifest/1" do
    spec_keys = LayerRegistry.param_keys() |> MapSet.new()

    manifest_keys =
      RenderParams.default() |> RenderParams.to_manifest() |> Map.keys() |> MapSet.new()

    missing = MapSet.difference(spec_keys, manifest_keys)
    assert MapSet.size(missing) == 0, "faltam em to_manifest: #{inspect(MapSet.to_list(missing))}"
  end

  test "Library.param_keys/0 inclui TODAS as chaves do catálogo" do
    spec_keys = LayerRegistry.param_keys() |> MapSet.new()
    lib_keys = Library.param_keys() |> MapSet.new()
    assert MapSet.subset?(spec_keys, lib_keys)
  end

  test "round-trip: to_manifest |> from_manifest preserva detect_skin/skin_sensitivity" do
    p1 = %{RenderParams.default() | detect_skin: true, skin_sensitivity: 0.7}

    p2 =
      RenderParams.from_manifest(
        %{"params" => RenderParams.to_manifest(p1)},
        RenderParams.default()
      )

    assert p2.detect_skin == true
    assert p2.skin_sensitivity == 0.7
  end

  test "round-trip: hair_model (mapa aprendido) sobrevive ao manifest" do
    model = %{"mu" => [50.0, 0.0, 0.0], "cov_inv" => [1.0, 0, 0, 0, 1.0, 0, 0, 0, 1.0]}
    p1 = %{RenderParams.default() | hair_model: model}

    p2 =
      RenderParams.from_manifest(
        %{"params" => RenderParams.to_manifest(p1)},
        RenderParams.default()
      )

    assert p2.hair_model == model
  end

  test "from_form preserva hair_model (vem do eyedropper, não do <form>)" do
    model = %{mu: [1.0, 2.0, 3.0], cov_inv: [1.0, 0, 0, 0, 1.0, 0, 0, 0, 1.0]}
    current = %{RenderParams.default() | hair_model: model}
    out = RenderParams.from_form(%{"halo" => "0.5"}, current)
    assert out.hair_model == model
  end
end
