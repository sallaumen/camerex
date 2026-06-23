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
    # honra o contrato do pipeline real: quem grava o desfecho é o pipeline
    def run(item_id, _progress_cb) do
      {:ok, _} =
        Camerex.Workspace.update_manifest(item_id, fn manifest ->
          manifest
          |> Map.put("status", "done")
          |> Map.put("completed_at", DateTime.to_iso8601(DateTime.utc_now()))
        end)

      :ok
    end
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

  describe "card-herói (última conversão)" do
    test "biblioteca destaca a última conversão pronta", %{conn: conn, tmp: tmp} do
      create_photo_item!(tmp, %{status: "done"})
      {:ok, lv, html} = live(conn, "/")

      assert html =~ ~s(id="hero")
      assert has_element?(lv, "#hero", "fonte.png")
      assert has_element?(lv, ~s(#hero [phx-click="open_item"]))
    end

    test "herói some com filtro ativo (é a vitrine da biblioteca pura)",
         %{conn: conn, tmp: tmp} do
      create_photo_item!(tmp, %{status: "done"})
      {:ok, lv, _} = live(conn, "/")
      assert has_element?(lv, "#hero")

      lv |> form("#filter-form", %{"q" => "zzz", "status" => ""}) |> render_change()
      refute has_element?(lv, "#hero")
    end

    test "herói some com o detalhe aberto", %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp, %{status: "done"})
      {:ok, lv, _} = live(conn, "/?item=#{id}")

      assert has_element?(lv, "#detail-panel")
      refute has_element?(lv, "#hero")
    end

    test "sem item pronto não há herói", %{conn: conn, tmp: tmp} do
      create_photo_item!(tmp)
      {:ok, lv, _} = live(conn, "/")
      refute has_element?(lv, "#hero")
    end
  end

  describe "detalhe in-place" do
    test "padrão sem destaque; card abre o detalhe; fechar volta à galeria",
         %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp, %{status: "done"})

      {:ok, lv, html} = live(conn, "/")
      refute html =~ "focus-zone"
      refute html =~ "detail-panel"

      lv |> element("#item-#{id} button[phx-click=open_item]") |> render_click()
      assert_patch(lv)
      assert render(lv) =~ "detail-panel"

      lv |> element("#close-detail") |> render_click()
      assert_patch(lv)
      refute render(lv) =~ "focus-zone"
    end

    test "+ nova conversão abre o painel; ✕ fecha de volta à galeria", %{conn: conn} do
      {:ok, lv, html} = live(conn, "/")
      refute html =~ "convert-panel"

      lv |> element("#new-conversion") |> render_click()
      assert render(lv) =~ "convert-panel"

      lv |> element("#close-convert") |> render_click()
      refute render(lv) =~ "convert-panel"
    end

    test "clicar em outra imagem durante o reprocesso troca o painel para ela",
         %{conn: conn, tmp: tmp} do
      a = create_photo_item!(tmp, %{status: "done"})
      b = create_photo_item!(tmp, %{status: "done"})

      {:ok, lv, _} = live(conn, "/?item=#{a}")
      lv |> element("#reconvert-button") |> render_click()
      assert render(lv) =~ "reconvert-chip"

      # clicar no card de B deve abrir o detalhe de B, não ficar preso em A
      lv |> element("#item-#{b} button[phx-click=open_item]") |> render_click()
      assert_patch(lv)
      html = render(lv)
      assert html =~ "detail-panel"
      refute html =~ "reconvert-chip"
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

    test "mídia processada leva versão na URL — reprocessar fura o cache do browser",
         %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp, %{status: "done"})
      {:ok, lv, _} = live(conn, "/?item=#{id}")

      # sem ?v= o browser reusa o neon.png antigo do cache após reprocessar
      [src_antes] = lv |> render() |> src_de("#after")
      assert src_antes =~ ~r{/media/items/#{id}/neon\.png\?v=\d+}

      lv |> element("#reconvert-button") |> render_click()
      lv |> form("#convert-form", %{"halo" => "0.8"}) |> render_submit()

      # o noop conclui async; o completed_at novo tem que virar ?v= novo
      src_depois =
        Enum.find_value(1..50, fn _ ->
          Process.sleep(20)

          case lv |> render() |> src_de("#after") do
            [s] when s != src_antes -> s
            _ -> nil
          end
        end)

      assert src_depois =~ ~r{\?v=\d+}
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

  describe "calibragem ao vivo" do
    test "reprocessar abre prévia ao vivo e o slider re-renderiza", %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp, %{status: "done"})
      {:ok, lv, _} = live(conn, "/?item=#{id}")

      lv |> element("#reconvert-button") |> render_click()
      assert render(lv) =~ "calib-preview"

      url_inicial = poll_calib_img(lv)
      assert url_inicial =~ "data:image/png;base64,"

      lv |> form("#convert-form", %{"halo" => "0.95"}) |> render_change()
      assert poll_calib_img(lv, url_inicial) != url_inicial
    end

    test "trocar a cor de uma camada re-renderiza a prévia", %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp, %{status: "done"})
      {:ok, lv, _} = live(conn, "/?item=#{id}")

      lv |> element("#reconvert-button") |> render_click()
      url_inicial = poll_calib_img(lv)

      lv |> form("#convert-form", %{"layer_clothing" => "#0000ff"}) |> render_change()
      assert poll_calib_img(lv, url_inicial) != url_inicial
    end

    test "aplicar nesta pasta leva a calibragem a todos os itens dela", %{conn: conn, tmp: tmp} do
      a = create_photo_item!(tmp, %{status: "done"})
      b = create_photo_item!(tmp, %{status: "done"})
      {:ok, lv, _} = live(conn, "/?item=#{a}")

      lv |> element("#reconvert-button") |> render_click()
      lv |> form("#convert-form", %{"halo" => "0.85"}) |> render_change()
      lv |> element("#apply-folder") |> render_click()

      for id <- [a, b] do
        assert {:ok, %{"params" => %{"halo" => 0.85}}} = Workspace.manifest(id)
      end

      assert render(lv) =~ "na fila"
    end

    test "aplicar na seleção só processa os selecionados", %{conn: conn, tmp: tmp} do
      alvo = create_photo_item!(tmp, %{status: "done"})
      selecionado = create_photo_item!(tmp, %{status: "done"})
      fora = create_photo_item!(tmp, %{status: "done"})

      {:ok, lv, _} = live(conn, "/?item=#{alvo}")
      lv |> element("#reconvert-button") |> render_click()

      # sem seleção o botão nem aparece
      refute render(lv) =~ "apply-selection"

      lv |> element("#item-#{selecionado} input[type=checkbox]") |> render_click()
      lv |> form("#convert-form", %{"halo" => "0.9"}) |> render_change()
      lv |> element("#apply-selection") |> render_click()

      assert {:ok, %{"params" => %{"halo" => 0.9}}} = Workspace.manifest(selecionado)
      assert {:ok, %{"params" => %{"halo" => halo_fora}}} = Workspace.manifest(fora)
      assert halo_fora != 0.9
    end

    test "cancelar o reprocesso desliga a prévia", %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp, %{status: "done"})
      {:ok, lv, _} = live(conn, "/?item=#{id}")

      lv |> element("#reconvert-button") |> render_click()
      assert poll_calib_img(lv)

      lv |> element("button[phx-click=reconvert_cancel]") |> render_click()
      refute render(lv) =~ "calib-preview"
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
          "halo" => 0.95,
          "trail" => 0.3,
          "detail" => 0.2,
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
      assert has_element?(lv, "#import-modal-overlay")
      refute has_element?(lv, "#import-modal-overlay[phx-click]")

      # Esc fecha via handler global da página
      lv |> element("#library-root") |> render_keydown()
      refute has_element?(lv, "#import-modal-overlay")
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
      assert has_element?(lv, "#import-modal-overlay")

      lv |> element("#library-root") |> render_keydown()
      refute has_element?(lv, "#import-modal-overlay")
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
      refute render(lv) =~ "detail-panel"
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

  describe "controle de bloom e presets de gradiente" do
    test "slider de bloom existe e atualiza o valor exibido", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/")
      lv |> element("#new-conversion") |> render_click()
      assert render(lv) =~ ~s(name="bloom")

      lv |> form("#convert-form", %{"bloom" => "0.85"}) |> render_change()
      assert render(lv) =~ "0.85"
    end

    test "cor-por-parte é padrão: os pickers de cor estão sempre à vista", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/")
      lv |> element("#new-conversion") |> render_click()

      assert render(lv) =~ "layer-pickers"
      assert has_element?(lv, "input[type=color][name=layer_clothing]")
      assert has_element?(lv, "input[type=color][name=layer_skin]")
    end

    test "toggle 'chão' revela os sliders de brilho e espalhamento", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/")
      lv |> element("#new-conversion") |> render_click()
      refute render(lv) =~ "floor-controls"

      lv |> form("#convert-form", %{"floor" => "true"}) |> render_change()

      assert has_element?(lv, "#floor-controls input[name=glow]")
      assert has_element?(lv, "#floor-controls input[name=spread]")
    end
  end

  describe "cores por parte em lote (JSON)" do
    setup %{conn: conn} do
      {:ok, lv, _} = live(conn, "/")
      lv |> element("#new-conversion") |> render_click()
      lv |> element("#edit-colors-json") |> render_click()
      %{lv: lv}
    end

    test "modal abre com o JSON das cores atuais (todas as partes)", %{lv: lv} do
      html = render(lv)
      assert html =~ "colors-json-modal"

      # textarea escapa as aspas (&quot;); o nome de cada parte aparece como substring
      for key <- ~w(skin hair hat clothing accessories object) do
        assert html =~ key
      end
    end

    test "aplica JSON hex válido (roupa azul) e fecha a modal", %{lv: lv} do
      lv |> form("#colors-json-form", %{"json" => ~s({"clothing": "#0000FF"})}) |> render_submit()

      refute render(lv) =~ "colors-json-modal"
      # Layers.hex devolve hex MAIÚSCULO
      assert has_element?(lv, ~s(input[name=layer_clothing][value="#0000FF"]))
    end

    test "também aceita [r, g, b] além de hex", %{lv: lv} do
      lv |> form("#colors-json-form", %{"json" => ~s({"hair": [0, 255, 0]})}) |> render_submit()

      assert has_element?(lv, ~s(input[name=layer_hair][value="#00FF00"]))
    end

    test "JSON inválido mostra erro e mantém a modal aberta", %{lv: lv} do
      lv |> form("#colors-json-form", %{"json" => "{ não é json"}) |> render_submit()

      html = render(lv)
      assert html =~ "colors-json-error"
      assert html =~ "colors-json-modal"
    end
  end

  describe "presets do usuário na UI" do
    test "salvar ajustes atuais e aplicar de volta", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/")
      lv |> element("#new-conversion") |> render_click()

      lv |> form("#convert-form", %{"halo" => "0.9"}) |> render_change()
      lv |> form("#save-preset-form", %{"name" => "Meu Show"}) |> render_submit()

      assert [preset] = UserPresets.all()
      # params agora ficam no sub-mapa "params" (antes era chave plana no topo)
      assert preset["params"]["halo"] == 0.9

      # muda o halo e re-aplica o preset salvo → restaura o 0.9
      lv |> form("#convert-form", %{"halo" => "0.2"}) |> render_change()
      lv |> element(~s(button[phx-click=apply_preset][phx-value-id="meu-show"])) |> render_click()

      assert render(lv) =~ ~s(value="0.9")
    end
  end

  describe "concorrência" do
    test "seletor do rail ajusta o pool", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/")

      lv |> form("#concurrency-form", %{"concurrency" => "5"}) |> render_change()

      assert Camerex.Settings.get("concurrency", 3) == 5
    end
  end

  defp src_de(html, seletor) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(seletor) |> LazyHTML.attribute("src")
  end

  # a prévia chega por Task async → handle_info; poll curto até aparecer
  # (ou até diferir de `diferente_de`, para esperar um re-render)
  defp poll_calib_img(lv, diferente_de \\ nil) do
    Enum.find_value(1..100, fn _ ->
      Process.sleep(10)

      case lv |> render() |> src_de("[data-role=calib-img]") do
        [src] when src != diferente_de -> src
        _ -> nil
      end
    end)
  end
end
