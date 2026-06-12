defmodule CamerexWeb.ItemVideoTest do
  use CamerexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  alias Camerex.Workspace

  setup %{tmp_dir: tmp_dir} do
    previous = Application.fetch_env!(:camerex, :workspace_root)
    Application.put_env(:camerex, :workspace_root, tmp_dir)
    on_exit(fn -> Application.put_env(:camerex, :workspace_root, previous) end)

    src = Path.join(tmp_dir, "src.mp4")
    File.write!(src, "bytes de mentira: o template só monta as URLs")
    {:ok, id} = Workspace.create_item(src, "clip.mp4", :video, "forro-duotone", %{})

    {:ok, _} =
      Workspace.update_manifest(id, fn m ->
        Map.merge(m, %{"status" => "done", "output_file" => "neon.mp4"})
      end)

    %{id: id}
  end

  test "item de vídeo done renderiza dois <video controls> servidos por /media",
       %{conn: conn, id: id} do
    {:ok, _lv, html} = live(conn, "/item/#{id}")

    assert html =~ ~s(data-role="video-original")
    assert html =~ ~s(src="/media/items/#{id}/original.mp4")
    assert html =~ ~s(data-role="video-neon")
    assert html =~ ~s(src="/media/items/#{id}/neon.mp4")
    assert html =~ "controls"
  end
end
