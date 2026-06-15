defmodule CamerexWeb.GalleryThemeTest do
  use CamerexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Camerex.Neon.Palette

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

  test "swatches dos 6 presets com data-swatch e cor exata da Palette", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("#new-conversion") |> render_click()
    html = render(view)

    for preset <- Palette.all() do
      assert html =~ ~s(data-swatch="#{preset.id}")
      assert html =~ Palette.hex(hd(preset.colors))
    end
  end
end
