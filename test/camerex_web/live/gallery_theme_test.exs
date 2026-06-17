defmodule CamerexWeb.GalleryThemeTest do
  use CamerexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    prev = Application.fetch_env!(:camerex, :workspace_root)
    Application.put_env(:camerex, :workspace_root, tmp)
    File.mkdir_p!(Path.join(tmp, "items"))
    on_exit(fn -> Application.put_env(:camerex, :workspace_root, prev) end)
    :ok
  end

  test "galeria vazia mostra empty state com call-to-action", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "gallery-empty"
    assert html =~ "neon-cta"
  end

  test "abrir 'nova conversão' mostra o painel cor-por-parte (pickers de cor)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("#new-conversion") |> render_click()

    assert has_element?(view, "#layer-pickers")
    assert has_element?(view, "input[type=color][name=layer_clothing]")
  end
end
