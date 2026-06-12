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

  describe "slug/1" do
    test "usa o nome sem extensão, minúsculo" do
      assert Workspace.slug("Casal.JPG") == "casal"
    end

    test "remove acentos via decomposição NFD" do
      assert Workspace.slug("Dança no Sertão.jpg") == "danca-no-sertao"
    end

    test "descarta emoji e colapsa espaços em um único hífen" do
      assert Workspace.slug("💃 forró  final 💃.png") == "forro-final"
    end

    test "nome sem nenhum caractere aproveitável vira \"item\"" do
      assert Workspace.slug("💃🕺.mp4") == "item"
    end

    test "trunca em 24 chars sem deixar hífen pendurado" do
      # "abcdefghij-klmnopqrstuv-xyz" cortado em 24 termina em "-",
      # que precisa ser aparado
      assert Workspace.slug("abcdefghij klmnopqrstuv xyz.mp4") ==
               "abcdefghij-klmnopqrstuv"
    end

    test "pontuação vira hífen único" do
      assert Workspace.slug("foto!!do  casal.jpg") == "foto-do-casal"
    end
  end

  describe "generate_id/2" do
    test "segue o formato <ts>-<slug>-<preset>-<rand4>" do
      id = Workspace.generate_id("casal.jpg", "forro-duotone")
      assert id =~ ~r/^\d{8}-\d{6}-casal-forro-duotone-[0-9a-f]{4}$/
    end

    test "timestamp usa o relógio de America/Sao_Paulo" do
      fmt = fn ->
        Calendar.strftime(DateTime.now!("America/Sao_Paulo"), "%Y%m%d-%H%M%S")
      end

      before_ts = fmt.()
      id = Workspace.generate_id("casal.jpg", "ouro")
      after_ts = fmt.()

      # nesse formato, comparação lexicográfica == cronológica
      ts = String.slice(id, 0, 15)
      assert ts >= before_ts and ts <= after_ts
    end

    test "sufixo aleatório distingue ids gerados no mesmo segundo" do
      ids = for _ <- 1..10, do: Workspace.generate_id("casal.jpg", "ouro")
      # probabilidade de 10 rand4 iguais: (1/65536)^9 — nunca flake
      assert ids |> Enum.uniq() |> length() > 1
    end
  end
end
