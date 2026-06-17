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

  test "reprocesso sobrescreve a conversão do mesmo item", %{tmp: tmp} do
    id = create_photo_item!(tmp)
    assert :ok = Photo.run(id, nil)
    bytes_v1 = File.read!(Workspace.item_path(id, "neon.png"))

    # novos ajustes direto no manifest (o caminho real é Library.process_items)
    {:ok, _} =
      Workspace.update_manifest(id, fn m ->
        Map.put(m, "params", Map.put(m["params"], "halo", 1.0))
      end)

    assert :ok = Photo.run(id, nil)

    {:ok, m} = Workspace.manifest(id)
    assert m["status"] == "done"
    # halo diferente → png diferente: a conversão foi de fato regravada
    refute File.read!(Workspace.item_path(id, "neon.png")) == bytes_v1
  end

  test "original ilegível: manifest failed com erro e exceção propagada", %{tmp: tmp} do
    src = Path.join(tmp, "quebrada.jpg")
    File.write!(src, "isto nao e uma imagem")

    {:ok, id} =
      Workspace.create_item(src, "quebrada.jpg", :photo, default_params())

    assert_raise RuntimeError, fn -> Photo.run(id, nil) end

    {:ok, m} = Workspace.manifest(id)
    assert m["status"] == "failed"
    assert is_binary(m["error"]) and m["error"] != ""
  end
end
