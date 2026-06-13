defmodule Camerex.Pipeline.FramePreviewTest do
  use Camerex.WorkspaceCase

  alias Camerex.Pipeline.FramePreview
  alias Camerex.Workspace

  @clip "exemplos/entrada/clip.mp4"

  test "middle_frame_rgb devolve o frame central como tensor RGB e limpa o tmp" do
    assert {:ok, rgb} = FramePreview.middle_frame_rgb(@clip)

    assert {_h, _w, 3} = Nx.shape(rgb)
    assert Nx.type(rgb) == {:u, 8}
    assert {:ok, []} = File.ls(Workspace.tmp_dir())
  end

  test "vídeo inexistente devolve erro sem deixar lixo no tmp" do
    assert {:error, _} = FramePreview.middle_frame_rgb("/nao/existe.mp4")
    assert {:ok, []} = File.ls(Workspace.tmp_dir())
  end
end
