defmodule CamerexWeb.LibraryLiveTest do
  use CamerexWeb.ConnCase, async: false

  import Camerex.WorkspaceCase
  import Phoenix.LiveViewTest

  alias Camerex.{Library, UserPresets, Workspace}

  @moduletag :tmp_dir

  setup :override_workspace_root

  setup do
    Application.put_env(:camerex, :photo_pipeline, CamerexWeb.LibraryLiveTest.PipelineNoop)
    on_exit(fn -> Application.delete_env(:camerex, :photo_pipeline) end)
    :ok
  end

  defmodule PipelineNoop do
    def run(_item_id, _progress_cb), do: :ok
  end

  describe "navegação por pastas (URL patchável)" do
    test "rail mostra a árvore e ?folder filtra o grid", %{conn: conn, tmp: tmp} do
      na_raiz = create_photo_item!(tmp)
      {:ok, _} = Library.create_folder("shows")
      em_shows = create_photo_item!(tmp)
      :ok = Library.move_items([em_shows], "shows")

      {:ok, lv, html} = live(conn, "/")
      assert html =~ ~s(data-folder="shows")
      assert html =~ "item-#{na_raiz}"
      refute html =~ "item-#{em_shows}"

      html = lv |> element(~s(#folder-tree button[data-folder="shows"])) |> render_click()
      assert_patch(lv)
      assert html =~ "item-#{em_shows}" or render(lv) =~ "item-#{em_shows}"
      refute render(lv) =~ "item-#{na_raiz}"
    end

    test "deep-link ?folder=&item= monta direto no estado certo", %{conn: conn, tmp: tmp} do
      {:ok, _} = Library.create_folder("shows")
      id = create_photo_item!(tmp, %{status: "done"})
      :ok = Library.move_items([id], "shows")

      {:ok, _lv, html} = live(conn, "/?folder=shows&item=#{id}")
      assert html =~ "detail-panel"
      assert html =~ "Reprocessar com ajustes"
    end

    test "/item/:id da v1 redireciona para a biblioteca", %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp)

      conn = get(conn, "/item/#{id}")
      assert redirected_to(conn) == "/?item=#{id}"
    end
  end

  describe "detalhe in-place" do
    test "clicar no card abre o painel; fechar volta ao convert", %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp, %{status: "done"})

      {:ok, lv, html} = live(conn, "/")
      assert html =~ "convert-panel"
      refute html =~ "detail-panel"

      lv |> element("#item-#{id} button[phx-click=open_item]") |> render_click()
      assert_patch(lv)
      assert render(lv) =~ "detail-panel"

      lv |> element("#close-detail") |> render_click()
      assert_patch(lv)
      assert render(lv) =~ "convert-panel"
    end

    test "apagar item do detalhe remove e volta à biblioteca", %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp, %{status: "done"})
      {:ok, lv, _} = live(conn, "/?item=#{id}")

      lv |> element("#delete") |> render_click()
      assert_patch(lv)

      assert Workspace.manifest(id) == {:error, :not_found}
      refute render(lv) =~ "item-#{id}"
    end

    test "duplicar cria item new na grade", %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp, %{status: "done"})
      {:ok, lv, _} = live(conn, "/?item=#{id}")

      lv |> element("#duplicate") |> render_click()

      assert [%{"id" => ^id}, %{"status" => "new"}] =
               Workspace.list_items() |> Enum.sort_by(& &1["status"])
    end

    test "reprocessar com ajustes pré-preenche e sobrescreve o MESMO item",
         %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp, %{status: "done"})
      {:ok, lv, _} = live(conn, "/?item=#{id}")

      lv |> element("#reconvert-button") |> render_click()
      html = render(lv)
      assert html =~ "reconvert-chip"
      assert html =~ "Reprocessar agora"

      lv |> form("#convert-form", %{"halo" => "0.9"}) |> render_submit()

      {:ok, m} = Workspace.manifest(id)
      assert m["params"]["halo"] == 0.9
      assert m["status"] in ["queued", "processing", "done"]
      assert length(Workspace.list_items()) == 1
    end
  end

  describe "seleção múltipla e massa" do
    test "checkboxes acumulam e a barra aparece com contagem", %{conn: conn, tmp: tmp} do
      a = create_photo_item!(tmp)
      b = create_photo_item!(tmp)

      {:ok, lv, html} = live(conn, "/")
      refute html =~ "selection-bar"

      lv |> element("#item-#{a} input[type=checkbox]") |> render_click()
      lv |> element("#item-#{b} input[type=checkbox]") |> render_click()

      assert render(lv) =~ "2 selecionado(s)"
    end

    test "processar seleção com preset salvo aplica os params do preset",
         %{conn: conn, tmp: tmp} do
      {:ok, _} =
        UserPresets.save(%{
          "name" => "Forte",
          "preset" => "pulp",
          "halo" => 0.95,
          "trail" => 0.3,
          "detail" => 0.2,
          "swap_sides" => false,
          "model" => "u2net"
        })

      # done: itens queued/processing são (corretamente) pulados pelo bulk
      id = create_photo_item!(tmp, %{status: "done"})
      {:ok, lv, _} = live(conn, "/")

      lv |> element("#item-#{id} input[type=checkbox]") |> render_click()

      lv
      |> element("#selection-bar form[phx-change=bulk_process_preset]")
      |> render_change(%{"preset_id" => "forte"})

      {:ok, m} = Workspace.manifest(id)
      assert m["preset"] == "pulp"
      assert m["params"]["halo"] == 0.95
    end

    test "mover seleção para pasta", %{conn: conn, tmp: tmp} do
      {:ok, _} = Library.create_folder("destino")
      id = create_photo_item!(tmp)
      {:ok, lv, _} = live(conn, "/")

      lv |> element("#item-#{id} input[type=checkbox]") |> render_click()

      lv
      |> element("#selection-bar form[phx-change=bulk_move]")
      |> render_change(%{"folder" => "destino"})

      assert {:ok, %{"folder" => "destino"}} = Workspace.manifest(id)
    end

    test "apagar seleção", %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp)
      {:ok, lv, _} = live(conn, "/")

      lv |> element("#item-#{id} input[type=checkbox]") |> render_click()
      lv |> element("#selection-bar button[phx-click=bulk_delete]") |> render_click()

      assert Workspace.list_items() == []
    end
  end

  describe "pastas e import" do
    test "nova pasta via modal aparece na árvore", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/")

      lv |> element("button[phx-value-modal=new_folder]") |> render_click()
      assert render(lv) =~ "new-folder-modal"

      lv |> form("#new-folder-form", %{"name" => "Eventos 2026"}) |> render_submit()
      assert_patch(lv)

      assert render(lv) =~ ~s(data-folder="eventos-2026")
    end

    test "import modal: scan + importar tudo cria itens new na pasta atual",
         %{conn: conn, tmp: tmp} do
      origem = Path.join(tmp, "origem")
      File.mkdir_p!(origem)
      rgb = Nx.broadcast(Nx.u8(99), {8, 8, 3})
      true = Evision.imwrite(Path.join(origem, "a.png"), Evision.Mat.from_nx_2d(rgb))
      true = Evision.imwrite(Path.join(origem, "b.png"), Evision.Mat.from_nx_2d(rgb))

      {:ok, lv, _} = live(conn, "/")
      lv |> element("#import-button") |> render_click()

      lv |> form("#import-form", %{"path" => origem}) |> render_submit()
      assert render(lv) =~ "2"

      lv |> element("#import-run") |> render_click()

      items = Workspace.list_items()
      assert length(items) == 2
      assert Enum.all?(items, &(&1["status"] == "new"))
    end

    test "overlay do modal não captura cliques de dentro do painel", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/")
      lv |> element("#import-button") |> render_click()

      # regressão: phx-click no overlay fechava o modal em QUALQUER clique
      # interno (borbulhado), inclusive no input de caminho — import inusável
      assert has_element?(lv, "#modal-overlay")
      refute has_element?(lv, "#modal-overlay[phx-click]")

      # Esc fecha via handler global da página
      lv |> element("#library-root") |> render_keydown()
      refute has_element?(lv, "#modal-overlay")
    end

    test "scan de caminho inexistente mostra erro no modal", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/")
      lv |> element("#import-button") |> render_click()

      lv |> form("#import-form", %{"path" => "/nao/existe"}) |> render_submit()
      assert render(lv) =~ "não encontrado"
    end
  end

  describe "tecla Esc (camadas)" do
    test "fecha o modal sem mexer no painel de detalhe", %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp, %{status: "done"})
      {:ok, lv, _} = live(conn, "/?item=#{id}")

      lv |> element("#import-button") |> render_click()
      assert has_element?(lv, "#modal-overlay")

      lv |> element("#library-root") |> render_keydown()
      refute has_element?(lv, "#modal-overlay")
      assert render(lv) =~ "detail-panel"
    end

    test "cancela o reprocesso antes de fechar o detalhe", %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp, %{status: "done"})
      {:ok, lv, _} = live(conn, "/?item=#{id}")

      lv |> element("#reconvert-button") |> render_click()
      assert render(lv) =~ "reconvert-chip"

      lv |> element("#library-root") |> render_keydown()
      refute render(lv) =~ "reconvert-chip"
      assert render(lv) =~ "detail-panel"

      lv |> element("#library-root") |> render_keydown()
      assert_patch(lv)
      assert render(lv) =~ "convert-panel"
    end
  end

  describe "busca e filtro de status" do
    test "busca por nome ignora acentos e mostra a contagem", %{conn: conn, tmp: tmp} do
      forro = create_photo_item!(tmp)

      {:ok, _} =
        Workspace.update_manifest(forro, &Map.put(&1, "original_filename", "Forró-Show.png"))

      tango = create_photo_item!(tmp)

      {:ok, lv, _} = live(conn, "/")

      lv |> form("#filter-form", %{"q" => "forro", "status" => ""}) |> render_change()

      assert has_element?(lv, "#item-#{forro}")
      refute has_element?(lv, "#item-#{tango}")
      assert lv |> element("[data-role=filter-count]") |> render() =~ "1 de 2"
    end

    test "filtro de status + estado vazio com limpar filtros", %{conn: conn, tmp: tmp} do
      done = create_photo_item!(tmp, %{status: "done"})
      failed = create_photo_item!(tmp, %{status: "failed"})

      {:ok, lv, _} = live(conn, "/")

      lv |> form("#filter-form", %{"q" => "", "status" => "failed"}) |> render_change()
      assert has_element?(lv, "#item-#{failed}")
      refute has_element?(lv, "#item-#{done}")

      lv |> form("#filter-form", %{"q" => "não-existe", "status" => "failed"}) |> render_change()
      assert has_element?(lv, "#filter-empty")

      lv |> element("#filter-empty button") |> render_click()
      assert has_element?(lv, "#item-#{done}")
      assert has_element?(lv, "#item-#{failed}")
      refute has_element?(lv, "#filter-empty")
    end

    test "selecionar tudo respeita o filtro ativo", %{conn: conn, tmp: tmp} do
      _done = create_photo_item!(tmp, %{status: "done"})
      _failed = create_photo_item!(tmp, %{status: "failed"})

      {:ok, lv, _} = live(conn, "/")

      lv |> form("#filter-form", %{"q" => "", "status" => "done"}) |> render_change()
      lv |> element("button[phx-click=select_all]") |> render_click()

      assert render(lv) =~ "1 selecionado(s)"
    end
  end

  describe "presets do usuário na UI" do
    test "salvar ajustes atuais e aplicar de volta", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/")

      lv |> element("button[phx-value-id=miami]") |> render_click()
      lv |> form("#convert-form", %{"halo" => "0.9"}) |> render_change()
      lv |> form("#save-preset-form", %{"name" => "Meu Show"}) |> render_submit()

      assert [preset] = UserPresets.all()
      assert preset["preset"] == "miami"
      assert preset["halo"] == 0.9

      # muda o painel e re-aplica o preset salvo
      lv |> element("button[phx-value-id=ouro]") |> render_click()
      lv |> element(~s(button[phx-click=apply_preset][phx-value-id="meu-show"])) |> render_click()

      html = render(lv)
      assert html =~ ~s(data-swatch="miami")
      assert html =~ ~s(value="0.9")
    end
  end

  describe "concorrência" do
    test "seletor do rail ajusta o pool", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/")

      lv |> form("#concurrency-form", %{"concurrency" => "5"}) |> render_change()

      assert Camerex.Settings.get("concurrency", 3) == 5
    end
  end
end
