defmodule Camerex.WorkspaceTest do
  use Camerex.WorkspaceCase

  alias Camerex.Workspace

  describe "diretórios" do
    test "root/0 devolve o workspace_root configurado", %{workspace_root: tmp} do
      assert Workspace.root() == tmp
    end

    test "items_dir/0 cria e devolve root/items" do
      dir = Workspace.items_dir()
      assert dir == Path.join(Workspace.root(), "items")
      assert File.dir?(dir)
    end

    test "tmp_dir/0 cria e devolve root/tmp" do
      dir = Workspace.tmp_dir()
      assert dir == Path.join(Workspace.root(), "tmp")
      assert File.dir?(dir)
    end
  end
end
