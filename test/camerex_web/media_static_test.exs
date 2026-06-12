defmodule CamerexWeb.MediaStaticTest do
  use CamerexWeb.ConnCase, async: false

  @moduletag :tmp_dir

  import Camerex.WorkspaceCase

  alias Camerex.Workspace

  setup :override_workspace_root

  # 12 bytes conhecidos: suficiente para testar 200 e Range/206
  defp seed_item_with_thumb!(tmp) do
    id = create_photo_item!(tmp)
    File.write!(Workspace.item_path(id, "thumb.jpg"), <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12>>)
    id
  end

  test "GET /media/items/<id>/thumb.jpg responde 200", %{conn: conn, tmp: tmp} do
    id = seed_item_with_thumb!(tmp)

    conn = get(conn, "/media/items/#{id}/thumb.jpg")

    assert conn.status == 200
    assert byte_size(conn.resp_body) == 12
  end

  test "pedido com Range responde 206 (seek de <video> no Safari)", %{conn: conn, tmp: tmp} do
    id = seed_item_with_thumb!(tmp)

    conn =
      conn
      |> put_req_header("range", "bytes=0-3")
      |> get("/media/items/#{id}/thumb.jpg")

    assert conn.status == 206
    assert byte_size(conn.resp_body) == 4
    assert [content_range] = get_resp_header(conn, "content-range")
    assert content_range =~ "bytes 0-3/12"
  end
end
