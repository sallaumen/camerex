defmodule CamerexWeb.GalleryLiveTest do
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
    assert has_element?(view, "#item-#{done} img[src='/media/items/#{done}/thumb.jpg']")
    assert has_element?(view, "#item-#{done} img[src='/media/items/#{done}/thumb_neon.jpg']")
    # item não-done ainda não tem thumbs: mostra placeholder
    assert has_element?(view, "#item-#{queued} [data-role=placeholder]")
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
end
