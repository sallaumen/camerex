defmodule Camerex.RenderParamsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Camerex.Parser.Layers
  alias Camerex.RenderParams

  @sliders ~w(halo bloom trail detail bg_opacity fill_color fill_texture glow spread)a
  @booleans ~w(detect_object transparent_bg fill floor)a

  describe "default/0" do
    test "traz as cores por camada e os defaults dos controles" do
      d = RenderParams.default()
      assert d.layer_colors == Layers.default_colors()
      assert d.preset_id == "forro-laranja"
      assert d.halo == 0.6
      assert d.fill == false
    end
  end

  describe "from_form/2" do
    test "parseia slider (string→float), mantém current onde falta" do
      d = RenderParams.default()
      out = RenderParams.from_form(%{"halo" => "0.9"}, d)
      assert out.halo == 0.9
      # bloom não veio no form: mantém o atual
      assert out.bloom == d.bloom
    end

    test "booleano vem de igualdade com 'true' (ausente ou 'false' vira false)" do
      d = RenderParams.default()
      assert RenderParams.from_form(%{"fill" => "true"}, d).fill == true
      assert RenderParams.from_form(%{"fill" => "false"}, d).fill == false
      assert RenderParams.from_form(%{}, d).fill == false
    end

    test "pickers de cor (hex) viram {r,g,b} sobre as cores atuais" do
      d = RenderParams.default()
      out = RenderParams.from_form(%{"layer_skin" => "#ff8800"}, d)
      assert out.layer_colors.skin == {255, 136, 0}
      # outras cores intactas
      assert out.layer_colors.hair == d.layer_colors.hair
    end
  end

  describe "from_manifest/2" do
    test "lê params já tipados do item e o preset" do
      d = RenderParams.default()
      item = %{"preset" => "miami", "params" => %{"halo" => 0.7, "fill" => true}}
      out = RenderParams.from_manifest(item, d)

      assert out.preset_id == "miami"
      assert out.halo == 0.7
      assert out.fill == true
      # slider ausente cai no fallback (current)
      assert out.bloom == d.bloom
    end

    test "item sem mapa \"params\" devolve o current" do
      d = RenderParams.default()
      assert RenderParams.from_manifest(%{"preset" => "x"}, d) == d
    end
  end

  describe "to_manifest/1" do
    test "produz exatamente as chaves do manifest (sem model nem preset_id)" do
      keys = RenderParams.default() |> RenderParams.to_manifest() |> Map.keys() |> Enum.sort()

      expected =
        ((@sliders ++ @booleans) |> Enum.map(&to_string/1)) ++ ["layer_colors"]

      assert keys == Enum.sort(expected)
      refute "model" in keys
      refute "preset_id" in keys
    end

    test "serializa as cores por camada como listas [r,g,b]" do
      m = RenderParams.default() |> RenderParams.to_manifest()
      assert m["layer_colors"]["skin"] == Tuple.to_list(RenderParams.default().layer_colors.skin)
    end
  end

  property "round-trip pelo manifest preserva todos os params (save → reprocesso)" do
    check all(p <- render_params()) do
      item = %{"preset" => p.preset_id, "params" => RenderParams.to_manifest(p)}
      restored = RenderParams.from_manifest(item, RenderParams.default())

      # o que vai pro manifest é idêntico depois do round-trip…
      assert RenderParams.to_manifest(restored) == RenderParams.to_manifest(p)
      # …e o preset (que viaja à parte) também
      assert restored.preset_id == p.preset_id
    end
  end

  # struct aleatório válido: sliders em [0,1] (passo 0.01), booleanos e preset
  defp render_params do
    gen all(
          sliders <- list_of(map(integer(0..100), &(&1 / 100.0)), length: length(@sliders)),
          bools <- list_of(boolean(), length: length(@booleans)),
          preset <- member_of(~w(forro-laranja forro-teal forro-duotone pulp miami ouro))
        ) do
      fields =
        @sliders
        |> Enum.zip(sliders)
        |> Map.new()
        |> Map.merge(@booleans |> Enum.zip(bools) |> Map.new())
        |> Map.put(:preset_id, preset)

      struct(RenderParams.default(), fields)
    end
  end
end
