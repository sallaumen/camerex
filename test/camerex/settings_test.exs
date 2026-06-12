defmodule Camerex.SettingsTest do
  use Camerex.WorkspaceCase

  alias Camerex.Settings

  test "get/2 devolve o default quando o arquivo não existe" do
    assert Settings.get("concurrency", 3) == 3
  end

  test "put/2 + get/2 fazem roundtrip persistido em disco" do
    assert :ok = Settings.put("concurrency", 5)
    assert Settings.get("concurrency", 3) == 5

    raw = File.read!(Path.join(Camerex.Workspace.root(), "settings.json"))
    assert raw =~ "concurrency"
  end

  test "put/2 preserva chaves existentes" do
    :ok = Settings.put("a", 1)
    :ok = Settings.put("b", "dois")

    assert Settings.get("a", nil) == 1
    assert Settings.get("b", nil) == "dois"
  end

  test "arquivo corrompido é tratado como vazio, sem crash" do
    File.write!(Path.join(Camerex.Workspace.root(), "settings.json"), "{nao é json")

    assert Settings.get("concurrency", 3) == 3
    assert :ok = Settings.put("concurrency", 2)
    assert Settings.get("concurrency", 3) == 2
  end
end
