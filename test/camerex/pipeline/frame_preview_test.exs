defmodule Camerex.Pipeline.FramePreviewTest do
  use Camerex.WorkspaceCase

  alias Camerex.Pipeline.FramePreview
  alias Camerex.Workspace

  @clip "exemplos/entrada/clip.mp4"
  @opts [preset: "forro-teal", halo: 0.6, detail: 0.5, swap_sides: false, model: "u2netp"]

  test "gera data URL de PNG do frame central e limpa o tmp" do
    assert {:ok, "data:image/png;base64," <> b64} = FramePreview.data_url(@clip, @opts)

    assert <<137, "PNG", _::binary>> = Base.decode64!(b64)
    assert {:ok, []} = File.ls(Workspace.tmp_dir())
  end

  test "vídeo inexistente devolve erro sem deixar lixo no tmp" do
    assert {:error, _} = FramePreview.data_url("/nao/existe.mp4", @opts)
    assert {:ok, []} = File.ls(Workspace.tmp_dir())
  end
end
