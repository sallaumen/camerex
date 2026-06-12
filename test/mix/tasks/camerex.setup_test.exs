defmodule Mix.Tasks.Camerex.SetupTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Camerex.Setup

  test "parse_argv/1 reconhece --force" do
    assert Setup.parse_argv([]) == %{force: false}
    assert Setup.parse_argv(["--force"]) == %{force: true}
  end

  test "action/2: pula modelo íntegro; baixa ausente/corrompido; --force sempre baixa" do
    assert Setup.action(:ok, false) == :skip
    assert Setup.action(:ok, true) == :download
    assert Setup.action(:missing, false) == :download
    assert Setup.action(:missing, true) == :download
    assert Setup.action(:bad_md5, false) == :download
    assert Setup.action(:bad_md5, true) == :download
  end
end
