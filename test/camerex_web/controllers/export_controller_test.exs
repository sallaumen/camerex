defmodule CamerexWeb.ExportControllerTest do
  use CamerexWeb.ConnCase, async: false

  import Camerex.WorkspaceCase

  @moduletag :tmp_dir

  alias Camerex.Workspace

  setup :override_workspace_root

  test "GET /export/folder baixa um zip dos resultados prontos", %{conn: conn, tmp: tmp} do
    id = create_photo_item!(tmp, %{status: "done"})

    {:ok, _} =
      Workspace.update_manifest(id, fn m ->
        Map.merge(m, %{"output_file" => "neon.png", "folder" => "ev"})
      end)

    File.write!(Workspace.item_path(id, "neon.png"), "ZIPME")

    conn = get(conn, ~p"/export/folder?folder=ev")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/zip"
    assert get_resp_header(conn, "content-disposition") |> List.first() =~ "camerex-ev.zip"
    assert byte_size(conn.resp_body) > 0
  end

  test "GET /export/folder sem resultados prontos -> 404", %{conn: conn} do
    conn = get(conn, ~p"/export/folder?folder=vazia")
    assert conn.status == 404
  end
end
