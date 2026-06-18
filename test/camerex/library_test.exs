defmodule Camerex.LibraryTest do
  use Camerex.WorkspaceCase

  alias Camerex.{Library, Workspace}

  defmodule PipelineNoop do
    def run(_item_id, _progress_cb), do: :ok
  end

  defp create_item_in!(tmp, folder, attrs \\ %{}) do
    src = Path.join(tmp, "f-#{System.unique_integer([:positive])}.png")
    rgb = Nx.broadcast(Nx.u8(120), {16, 16, 3})
    true = Evision.imwrite(src, Evision.Mat.from_nx_2d(rgb))

    {:ok, id} =
      Workspace.create_item(src, "foto.png", :photo, default_params(), folder: folder)

    case attrs[:status] do
      nil ->
        id

      status ->
        with({:ok, _} <- Workspace.update_manifest(id, &Map.put(&1, "status", status))) do
          id
        end
    end
  end

  describe "pastas" do
    test "create_folder normaliza, registra e aparece na tree com contagem 0" do
      assert {:ok, "shows/2026"} = Library.create_folder("Shows/2026")
      assert [%{path: "shows", count: 0}, %{path: "shows/2026", count: 0}] = Library.tree()
    end

    test "create_folder inválida devolve erro" do
      assert {:error, _} = Library.create_folder("../fuga")
    end

    test "tree une folders.json com pastas dos itens e conta itens diretos", %{tmp: tmp} do
      {:ok, _} = Library.create_folder("vazia")
      create_item_in!(tmp, "shows/2026")
      create_item_in!(tmp, "shows/2026")
      create_item_in!(tmp, "shows")

      assert Library.tree() == [
               %{path: "shows", count: 1},
               %{path: "shows/2026", count: 2},
               %{path: "vazia", count: 0}
             ]
    end

    test "delete_folder só remove pasta vazia (sem itens e sem subpastas)", %{tmp: tmp} do
      id = create_item_in!(tmp, "cheia")
      {:ok, _} = Library.create_folder("pai/filha")

      assert {:error, :not_empty} = Library.delete_folder("cheia")
      assert {:error, :not_empty} = Library.delete_folder("pai")

      Library.delete_items([id])
      assert :ok = Library.delete_folder("cheia")
      assert :ok = Library.delete_folder("pai/filha")
      assert :ok = Library.delete_folder("pai")
    end
  end

  describe "snapshot/1" do
    test "equivale a items_in + tree + contagem da raiz num scan só", %{tmp: tmp} do
      raiz = create_item_in!(tmp, "")
      create_item_in!(tmp, "shows")
      {:ok, _} = Library.create_folder("vazia")

      snapshot = Library.snapshot("shows")

      assert snapshot.items == Library.items_in("shows")
      assert snapshot.tree == Library.tree()
      assert snapshot.root_count == 1
      assert [%{"id" => ^raiz}] = Library.snapshot("").items
    end
  end

  describe "itens" do
    test "items_in/1 devolve só a pasta exata, recentes primeiro", %{tmp: tmp} do
      a = create_item_in!(tmp, "shows")
      _sub = create_item_in!(tmp, "shows/2026")
      b = create_item_in!(tmp, "shows")

      {:ok, _} =
        Workspace.update_manifest(a, &Map.put(&1, "created_at", "2026-06-12T10:00:00-03:00"))

      {:ok, _} =
        Workspace.update_manifest(b, &Map.put(&1, "created_at", "2026-06-12T11:00:00-03:00"))

      assert Enum.map(Library.items_in("shows"), & &1["id"]) == [b, a]
      assert Library.items_in("") == []
    end

    test "move_items muda a pasta e registra a pasta destino", %{tmp: tmp} do
      id = create_item_in!(tmp, "")

      assert :ok = Library.move_items([id], "Nova/Pasta")
      assert {:ok, %{"folder" => "nova/pasta"}} = Workspace.manifest(id)
      assert %{path: "nova/pasta"} = Enum.find(Library.tree(), &(&1.path == "nova/pasta"))
    end

    test "duplicate_item copia o original e nasce new na mesma pasta", %{tmp: tmp} do
      id = create_item_in!(tmp, "shows", %{status: "done"})

      assert {:ok, new_id} = Library.duplicate_item(id)
      assert new_id != id

      {:ok, dup} = Workspace.manifest(new_id)
      assert dup["status"] == "new"
      assert dup["folder"] == "shows"
      assert File.exists?(Workspace.item_path(new_id, dup["original_file"]))
    end

    test "process_items aplica params, enfileira e pula processing/queued", %{tmp: tmp} do
      Application.put_env(:camerex, :photo_pipeline, PipelineNoop)
      on_exit(fn -> Application.delete_env(:camerex, :photo_pipeline) end)

      novo = create_item_in!(tmp, "")
      {:ok, _} = Workspace.update_manifest(novo, &Map.put(&1, "status", "new"))
      ocupado = create_item_in!(tmp, "", %{status: "processing"})

      params = %{
        "halo" => 0.9,
        "trail" => 0.7,
        "detail" => 0.5,
        "model" => "u2net"
      }

      assert %{enqueued: 1, skipped: 1} = Library.process_items([novo, ocupado], params)

      {:ok, m} = Workspace.manifest(novo)
      assert m["params"]["halo"] == 0.9
      assert m["status"] in ["queued", "processing", "done"]

      # o item ocupado é pulado: segue em processing, sem re-enfileirar
      {:ok, untouched} = Workspace.manifest(ocupado)
      assert untouched["status"] == "processing"
    end

    test "process_items persiste os params novos (bloom/camada/chão)", %{tmp: tmp} do
      Application.put_env(:camerex, :photo_pipeline, PipelineNoop)
      on_exit(fn -> Application.delete_env(:camerex, :photo_pipeline) end)

      id = create_item_in!(tmp, "", %{status: "new"})

      params = %{
        "halo" => 0.6,
        "bloom" => 0.8,
        "trail" => 0.7,
        "detail" => 0.5,
        "model" => "u2net",
        "layer_colors" => %{"clothing" => [0, 0, 255]},
        "detect_object" => true,
        "detect_aerial" => true,
        "bg_opacity" => 0.3,
        "transparent_bg" => true,
        "fill" => true,
        "fill_color" => 0.5,
        "fill_texture" => 0.12,
        "floor" => true,
        "glow" => 0.6,
        "spread" => 0.4
      }

      assert %{enqueued: 1} = Library.process_items([id], params)

      {:ok, m} = Workspace.manifest(id)
      assert m["params"]["bloom"] == 0.8
      assert m["params"]["layer_colors"] == %{"clothing" => [0, 0, 255]}
      assert m["params"]["detect_object"] == true
      assert m["params"]["detect_aerial"] == true
      assert m["params"]["bg_opacity"] == 0.3
      assert m["params"]["transparent_bg"] == true
      assert m["params"]["fill"] == true
      assert m["params"]["fill_color"] == 0.5
      assert m["params"]["fill_texture"] == 0.12
      assert m["params"]["floor"] == true
      assert m["params"]["glow"] == 0.6
      assert m["params"]["spread"] == 0.4
    end
  end
end
