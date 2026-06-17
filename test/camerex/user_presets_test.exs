defmodule Camerex.UserPresetsTest do
  use Camerex.WorkspaceCase

  alias Camerex.UserPresets

  # um preset realista: TODOS os controles do painel (não só os antigos), pra
  # travar a regressão "preset não salvava as configs novas"
  @valid %{
    "name" => "Show Noturno",
    "preset" => "miami",
    "halo" => 0.8,
    "bloom" => 0.4,
    "trail" => 0.5,
    "detail" => 0.4,
    "layer_colors" => %{"clothing" => [0, 0, 255]},
    "detect_object" => true,
    "bg_opacity" => 0.3,
    "transparent_bg" => true,
    "fill" => true,
    "fill_color" => 0.5,
    "fill_texture" => 0.12,
    "floor" => true,
    "glow" => 0.6,
    "spread" => 0.4,
    "model" => "u2netp"
  }

  test "save/1 válido gera id slug e persiste; all/0 devolve" do
    assert {:ok, saved} = UserPresets.save(@valid)
    assert saved["id"] == "show-noturno"
    assert saved["preset"] == "miami"

    assert [%{"id" => "show-noturno"}] = UserPresets.all()
  end

  test "save/1 guarda TODOS os params novos (regressão: não dropar config)" do
    {:ok, saved} = UserPresets.save(@valid)
    params = saved["params"]

    # os controles novos sobrevivem ao save
    assert params["bloom"] == 0.4
    assert params["layer_colors"] == %{"clothing" => [0, 0, 255]}
    assert params["detect_object"] == true
    assert params["bg_opacity"] == 0.3
    assert params["transparent_bg"] == true
    assert params["fill"] == true
    assert params["fill_color"] == 0.5
    assert params["fill_texture"] == 0.12
    assert params["floor"] == true
    assert params["glow"] == 0.6
    assert params["spread"] == 0.4
  end

  test "save/1 é upsert por nome (mesmo id substitui)" do
    {:ok, _} = UserPresets.save(@valid)
    {:ok, _} = UserPresets.save(%{@valid | "halo" => 0.2})

    assert [%{"params" => %{"halo" => 0.2}}] = UserPresets.all()
  end

  test "get/1 acha por id; desconhecido devolve nil" do
    {:ok, _} = UserPresets.save(@valid)
    assert %{"name" => "Show Noturno"} = UserPresets.get("show-noturno")
    assert UserPresets.get("nope") == nil
  end

  test "delete/1 remove e é idempotente" do
    {:ok, _} = UserPresets.save(@valid)
    assert :ok = UserPresets.delete("show-noturno")
    assert UserPresets.all() == []
    assert :ok = UserPresets.delete("show-noturno")
  end

  test "validações: nome vazio, preset base inexistente, ranges e modelo" do
    assert {:error, msg} = UserPresets.save(%{@valid | "name" => "  "})
    assert msg =~ "nome"

    assert {:error, msg} = UserPresets.save(%{@valid | "preset" => "vaporwave"})
    assert msg =~ "preset"

    assert {:error, msg} = UserPresets.save(%{@valid | "halo" => 1.5})
    assert msg =~ "halo"

    assert {:error, msg} = UserPresets.save(%{@valid | "trail" => 0.99})
    assert msg =~ "trail"

    assert {:error, msg} = UserPresets.save(%{@valid | "model" => "yolo"})
    assert msg =~ "model"
  end

  test "arquivo corrompido é tratado como vazio" do
    File.write!(Path.join(Camerex.Workspace.root(), "user_presets.json"), "{quebrado")
    assert UserPresets.all() == []
    assert {:ok, _} = UserPresets.save(@valid)
    assert length(UserPresets.all()) == 1
  end

  test "params/1 devolve o mapa de params inteiro do preset salvo" do
    {:ok, saved} = UserPresets.save(@valid)
    assert UserPresets.params(saved) == Map.drop(@valid, ["name", "preset"])
  end

  test "params/1 de preset antigo (chaves planas, sem 'params') usa fallback" do
    legacy = %{
      "id" => "antigo",
      "name" => "Antigo",
      "preset" => "miami",
      "halo" => 0.6,
      "trail" => 0.7,
      "detail" => 0.5,
      "swap_sides" => false,
      "model" => "u2net"
    }

    assert UserPresets.params(legacy) == %{
             "halo" => 0.6,
             "trail" => 0.7,
             "detail" => 0.5,
             "swap_sides" => false,
             "model" => "u2net"
           }
  end
end
