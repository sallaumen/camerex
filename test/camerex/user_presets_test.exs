defmodule Camerex.UserPresetsTest do
  use Camerex.WorkspaceCase

  alias Camerex.UserPresets

  @valid %{
    "name" => "Show Noturno",
    "preset" => "miami",
    "halo" => 0.8,
    "trail" => 0.5,
    "detail" => 0.4,
    "swap_sides" => true,
    "model" => "u2netp"
  }

  test "save/1 válido gera id slug e persiste; all/0 devolve" do
    assert {:ok, saved} = UserPresets.save(@valid)
    assert saved["id"] == "show-noturno"
    assert saved["preset"] == "miami"

    assert [%{"id" => "show-noturno"}] = UserPresets.all()
  end

  test "save/1 é upsert por nome (mesmo id substitui)" do
    {:ok, _} = UserPresets.save(@valid)
    {:ok, _} = UserPresets.save(%{@valid | "halo" => 0.2})

    assert [%{"halo" => 0.2}] = UserPresets.all()
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

  test "params/1 extrai o mapa de params de conversão do preset salvo" do
    {:ok, saved} = UserPresets.save(@valid)

    assert UserPresets.params(saved) == %{
             "halo" => 0.8,
             "trail" => 0.5,
             "detail" => 0.4,
             "swap_sides" => true,
             "model" => "u2netp"
           }
  end
end
