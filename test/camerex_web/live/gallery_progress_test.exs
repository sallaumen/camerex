defmodule CamerexWeb.GalleryProgressTest do
  use CamerexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  alias Camerex.Workspace

  setup %{tmp_dir: tmp_dir} do
    previous = Application.fetch_env!(:camerex, :workspace_root)
    Application.put_env(:camerex, :workspace_root, tmp_dir)
    on_exit(fn -> Application.put_env(:camerex, :workspace_root, previous) end)

    src = Path.join(tmp_dir, "src.mp4")
    File.write!(src, "bytes de mentira: o card não toca o arquivo")
    {:ok, id} = Workspace.create_item(src, "clip.mp4", :video, "forro-duotone", %{})
    {:ok, _} = Workspace.update_manifest(id, &Map.put(&1, "status", "processing"))

    %{id: id}
  end

  test "card processing assina job:<id> e atualiza a barra com o broadcast",
       %{conn: conn, id: id} do
    {:ok, lv, html} = live(conn, "/")

    # antes do primeiro broadcast: placeholder
    assert html =~ ~s(data-role="job-progress")
    assert html =~ "processando"

    Phoenix.PubSub.broadcast(
      Camerex.PubSub,
      "job:#{id}",
      {:job_progress, id, %{done: 5, total: 10, eta_s: 12.5}}
    )

    html = render(lv)
    assert html =~ "width: 50.0%"
    assert html =~ "5/10"
    assert html =~ "~13s" or html =~ "~12s"
  end
end
