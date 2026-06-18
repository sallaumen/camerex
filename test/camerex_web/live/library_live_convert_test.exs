defmodule CamerexWeb.LibraryLiveConvertTest.PipelineNoop do
  @moduledoc "Pipeline inerte: o teste só verifica criação/enfileiramento."
  def run(_item_id, _progress_cb), do: :ok
end

defmodule CamerexWeb.LibraryLiveConvertTest do
  use CamerexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  import Camerex.WorkspaceCase

  alias Camerex.Workspace

  setup :override_workspace_root

  test "lista itens com chips de tipo e status e thumbs antes/depois", %{conn: conn, tmp: tmp} do
    done = create_photo_item!(tmp, %{status: "done"})
    queued = create_photo_item!(tmp, %{status: "queued"})

    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "item-#{done}"
    assert html =~ "item-#{queued}"
    assert has_element?(view, "#item-#{done} [data-role=status-chip]", "pronto")
    assert has_element?(view, "#item-#{queued} [data-role=status-chip]", "na fila")
    assert has_element?(view, "#item-#{done} [data-role=type-chip]", "foto")
    # ^= porque thumbs levam ?v= (cache-buster derivado do completed_at)
    assert has_element?(view, "#item-#{done} img[src^='/media/items/#{done}/thumb.jpg?v=']")
    assert has_element?(view, "#item-#{done} img[src^='/media/items/#{done}/thumb_neon.jpg?v=']")
    # foto não-done ainda não tem thumbs: mostra o original como prévia
    assert has_element?(view, "#item-#{queued} img[alt^=original]")
    refute has_element?(view, "#item-#{queued} [data-role=placeholder]")
  end

  test "galeria vazia mostra estado vazio", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#gallery-empty")
  end

  test "{:jobs_changed} recarrega a lista", %{conn: conn, tmp: tmp} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "article[id^=item-]")

    id = create_photo_item!(tmp, %{status: "queued"})
    Phoenix.PubSub.broadcast(Camerex.PubSub, "jobs", {:jobs_changed})

    assert has_element?(view, "#item-#{id}")
  end

  describe "painel de conversão" do
    setup do
      Application.put_env(
        :camerex,
        :photo_pipeline,
        CamerexWeb.LibraryLiveConvertTest.PipelineNoop
      )

      on_exit(fn -> Application.delete_env(:camerex, :photo_pipeline) end)
      :ok
    end

    test "cor-por-parte é o padrão: pickers de cor à vista, sem swatches/chroma", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#new-conversion") |> render_click()

      # cor-por-parte virou o único modo → pickers sempre presentes…
      assert has_element?(view, "#layer-pickers")
      # …e a UI antiga (swatches de preset, slider 'cor', 'inverter lados') saiu
      refute has_element?(view, "#preset-swatches")
      refute has_element?(view, "#convert-form input[name=chroma]")
      refute has_element?(view, "#swap-sides")
    end

    test "upload de foto cria item queued com params e enfileira o job", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#new-conversion") |> render_click()

      photo =
        file_input(view, "#convert-form", :media, [
          %{
            name: "casal.jpg",
            content: File.read!("exemplos/entrada/casal.jpg"),
            type: "image/jpeg"
          }
        ])

      assert render_upload(photo, "casal.jpg") =~ "100%"

      view
      |> form("#convert-form", %{"halo" => "0.8", "trail" => "0.7", "detail" => "0.5"})
      |> render_submit()

      assert [item] = Workspace.list_items()
      assert item["type"] == "photo"
      assert item["original_filename"] == "casal.jpg"
      assert item["params"]["halo"] == 0.8
      assert item["params"]["trail"] == 0.7
      assert item["params"]["detail"] == 0.5
      assert item["params"]["model"] == "u2net"
      # o Jobs global pega o item na hora; com o pipeline noop ele fica em processing
      assert item["status"] in ["queued", "processing"]

      # o card novo aparece na grade sem refresh
      assert has_element?(view, "#item-#{item["id"]}")
    end

    test "'Só importar' cria item 'new' sem enfileirar job", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#new-conversion") |> render_click()

      photo =
        file_input(view, "#convert-form", :media, [
          %{
            name: "casal.jpg",
            content: File.read!("exemplos/entrada/casal.jpg"),
            type: "image/jpeg"
          }
        ])

      assert render_upload(photo, "casal.jpg") =~ "100%"

      view |> element("#import-only") |> render_click()

      assert [item] = Workspace.list_items()
      assert item["status"] == "new"
      assert item["output_file"] == nil
      # importado, painel volta ao placeholder e o card aparece
      assert has_element?(view, "#item-#{item["id"]}")
      refute render(view) =~ "convert-panel"
    end
  end

  describe "controles do painel cor-por-parte" do
    test "reprocesso de foto esconde 'rastro' (no-op em foto; halo segue)",
         %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp, %{status: "done"})
      {:ok, view, _} = live(conn, "/?item=#{id}")
      view |> element("#reconvert-button") |> render_click()

      refute has_element?(view, "#convert-form input[name=trail]")
      assert has_element?(view, "#convert-form input[name=halo]")
    end

    test "preenchimento: toggle sempre à vista; sliders de opacidade só ao ligar",
         %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("#new-conversion") |> render_click()

      # cor-por-parte é padrão → o toggle de preenchimento está sempre presente,
      # mas os sliders de opacidade só aparecem quando ligado
      assert has_element?(view, "#fill-toggle")
      refute has_element?(view, "#convert-form input[name=fill_color]")

      view |> form("#convert-form", %{"fill" => "true"}) |> render_change()
      # com preenchimento ligado: entram os DOIS sliders (cor e textura)
      assert has_element?(view, "#convert-form input[name=fill_color]")
      assert has_element?(view, "#convert-form input[name=fill_texture]")
    end

    test "objeto/instrumento: toggle sempre à vista; picker de cor só ao ligar",
         %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("#new-conversion") |> render_click()

      # o toggle do objeto está sempre presente, mas o picker só ao ligar
      assert has_element?(view, "#object-toggle")
      refute has_element?(view, "#convert-form input[name=layer_object]")

      view |> form("#convert-form", %{"detect_object" => "true"}) |> render_change()

      # objeto ligado: entra o picker de cor da camada do objeto
      assert has_element?(view, "#object-color")
      assert has_element?(view, "#convert-form input[name=layer_object]")
    end

    test "modo aéreo: toggle sempre à vista; picker do tecido só ao ligar",
         %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("#new-conversion") |> render_click()

      assert has_element?(view, "#aerial-toggle")
      refute has_element?(view, "#convert-form input[name=layer_apparatus]")

      view |> form("#convert-form", %{"detect_aerial" => "true"}) |> render_change()

      # tecido ligado: entra o picker de cor da camada do tecido aéreo
      assert has_element?(view, "#aerial-color")
      assert has_element?(view, "#convert-form input[name=layer_apparatus]")
    end

    test "fundo: controles sempre presentes (slider de opacidade + toggle transparente)",
         %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("#new-conversion") |> render_click()

      # controles de fundo são globais (valem no modo normal e no cor-por-parte)
      assert has_element?(view, "#background-controls")
      assert has_element?(view, "#convert-form input[name=bg_opacity]")
      assert has_element?(view, "#transparent-toggle")

      # liga o fundo transparente e confirma que o estado persiste no checkbox
      view |> form("#convert-form", %{"transparent_bg" => "true"}) |> render_change()
      assert has_element?(view, "#transparent-toggle input[type=checkbox][checked]")
    end
  end

  describe "dashboard de performance" do
    test "presente no canto e ajusta threads/frame do vídeo", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#perf-dashboard")
      assert has_element?(view, "#frame-concurrency-form input[name=frame_concurrency]")

      # ajustar o controle reflete no valor do input (e persiste via Settings)
      view |> form("#frame-concurrency-form", %{"frame_concurrency" => "8"}) |> render_change()
      assert has_element?(view, ~s(#frame-concurrency[value="8"]))
    end
  end

  describe "meus presets" do
    test "salvar+aplicar preset restaura TODAS as configs (não só halo/trail)",
         %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("#new-conversion") |> render_click()

      # liga configs NOVAS (preenchimento, fundo transparente, opacidade do fundo)
      view
      |> form("#convert-form", %{
        "fill" => "true",
        "transparent_bg" => "true",
        "bg_opacity" => "0.4"
      })
      |> render_change()

      # salva como preset
      view |> form("#save-preset-form", %{"name" => "meu preset"}) |> render_submit()

      # zera tudo de volta
      view
      |> form("#convert-form", %{
        "fill" => "false",
        "transparent_bg" => "false",
        "bg_opacity" => "0"
      })
      |> render_change()

      refute has_element?(view, "#transparent-toggle input[type=checkbox][checked]")

      # aplica o preset salvo -> restaura as 3 configs novas
      view |> element("button[phx-value-id='meu-preset']") |> render_click()

      assert has_element?(view, "#fill-toggle input[type=checkbox][checked]")
      assert has_element?(view, "#transparent-toggle input[type=checkbox][checked]")
      assert has_element?(view, ~s(#convert-form input[name=bg_opacity][value="0.4"]))
    end
  end
end
