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

    test "mostra os 6 swatches; seleção controla o 'inverter lados'", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#new-conversion") |> render_click()

      for id <- ~w(forro-laranja forro-teal forro-duotone pulp miami ouro) do
        assert has_element?(view, "#preset-swatches button[phx-value-id=#{id}]")
      end

      # default forro-laranja é mono: sem "inverter lados"
      refute has_element?(view, "#swap-sides")

      view |> element("button[phx-value-id=forro-duotone]") |> render_click()
      assert has_element?(view, "button[phx-value-id=forro-duotone][data-selected=true]")
      assert has_element?(view, "#swap-sides")

      view |> element("button[phx-value-id=forro-teal]") |> render_click()
      refute has_element?(view, "#swap-sides")
    end

    test "upload de foto cria item queued com params e enfileira o job", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#new-conversion") |> render_click()

      view |> element("button[phx-value-id=forro-teal]") |> render_click()

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
      assert item["preset"] == "forro-teal"
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

  describe "cor-por-parte esconde controles irrelevantes" do
    test "ligar cor-por-parte esconde swatches de preset e o slider 'cor'", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("#new-conversion") |> render_click()

      # sem layered: swatches de preset e 'cor' (chroma) estão visíveis
      assert has_element?(view, "#preset-swatches")
      assert has_element?(view, "#convert-form input[name=chroma]")

      view |> form("#convert-form", %{"layered" => "true"}) |> render_change()

      # com layered: a cor vem dos pickers → swatches e 'cor' somem, pickers entram
      refute has_element?(view, "#preset-swatches")
      refute has_element?(view, "#convert-form input[name=chroma]")
      assert has_element?(view, "#layer-pickers")
    end

    test "reprocesso de foto esconde 'rastro' (no-op em foto; halo segue)",
         %{conn: conn, tmp: tmp} do
      id = create_photo_item!(tmp, %{status: "done"})
      {:ok, view, _} = live(conn, "/?item=#{id}")
      view |> element("#reconvert-button") |> render_click()

      refute has_element?(view, "#convert-form input[name=trail]")
      assert has_element?(view, "#convert-form input[name=halo]")
    end

    test "preenchimento: toggle só com layered; slider de opacidade ao ligar", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("#new-conversion") |> render_click()

      # sem layered, sem preenchimento
      refute has_element?(view, "#fill-toggle")

      view |> form("#convert-form", %{"layered" => "true"}) |> render_change()
      # com layered: o toggle aparece, mas os sliders de opacidade ainda não
      assert has_element?(view, "#fill-toggle")
      refute has_element?(view, "#convert-form input[name=fill_color]")

      view |> form("#convert-form", %{"layered" => "true", "fill" => "true"}) |> render_change()
      # com preenchimento ligado: entram os DOIS sliders (cor e textura)
      assert has_element?(view, "#convert-form input[name=fill_color]")
      assert has_element?(view, "#convert-form input[name=fill_texture]")
    end

    test "objeto/instrumento: toggle só com layered; picker de cor ao ligar", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("#new-conversion") |> render_click()

      # sem layered: nem o toggle nem o picker do objeto existem
      refute has_element?(view, "#object-toggle")
      refute has_element?(view, "#convert-form input[name=layer_object]")

      view |> form("#convert-form", %{"layered" => "true"}) |> render_change()
      # com layered: o toggle aparece, mas o picker do objeto ainda não
      assert has_element?(view, "#object-toggle")
      refute has_element?(view, "#convert-form input[name=layer_object]")

      view
      |> form("#convert-form", %{"layered" => "true", "detect_object" => "true"})
      |> render_change()

      # objeto ligado: entra o picker de cor da camada do objeto
      assert has_element?(view, "#object-color")
      assert has_element?(view, "#convert-form input[name=layer_object]")
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
end
