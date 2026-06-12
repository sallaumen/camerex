defmodule Camerex.Pipeline.PhotoRunTest do
  use Camerex.WorkspaceCase

  alias Camerex.Pipeline.Photo
  alias Camerex.Workspace

  test "processa item de foto: grava neon.png, thumbs e manifest done", %{tmp: tmp} do
    id = create_photo_item!(tmp)

    assert :ok = Photo.run(id, nil)

    assert File.exists?(Workspace.item_path(id, "neon.png"))
    assert File.exists?(Workspace.item_path(id, "thumb.jpg"))
    assert File.exists?(Workspace.item_path(id, "thumb_neon.jpg"))

    {:ok, m} = Workspace.manifest(id)
    assert m["status"] == "done"
    assert m["output_file"] == "neon.png"
    assert m["error"] == nil
    assert is_integer(m["timings_ms"]["total"]) and m["timings_ms"]["total"] >= 0
    assert m["media"]["width"] == 48
    assert m["media"]["height"] == 32
    assert is_binary(m["completed_at"])
  end

  test "chama progress_cb com (1, 1) ao concluir", %{tmp: tmp} do
    id = create_photo_item!(tmp)
    me = self()

    assert :ok = Photo.run(id, fn done, total -> send(me, {:cb, done, total}) end)
    assert_received {:cb, 1, 1}
  end

  test "original ilegível: manifest failed com erro e exceção propagada", %{tmp: tmp} do
    src = Path.join(tmp, "quebrada.jpg")
    File.write!(src, "isto nao e uma imagem")

    {:ok, id} =
      Workspace.create_item(src, "quebrada.jpg", :photo, "forro-teal", default_params())

    assert_raise RuntimeError, fn -> Photo.run(id, nil) end

    {:ok, m} = Workspace.manifest(id)
    assert m["status"] == "failed"
    assert is_binary(m["error"]) and m["error"] != ""
  end
end
