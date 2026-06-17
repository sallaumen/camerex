defmodule Camerex.Video.AudioTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Camerex.Video.Audio

  test "anexa o áudio do original ao vídeo mudo (mesma duração)", %{tmp_dir: tmp} do
    source = with_audio(tmp, "source.mp4")
    video = muted(tmp, "neon.mp4")

    refute has_audio?(video)
    assert :ok = Audio.attach(video, source)
    assert has_audio?(video)
  end

  test "origem sem áudio: no-op, o vídeo fica intacto", %{tmp_dir: tmp} do
    source = muted(tmp, "source.mp4")
    video = muted(tmp, "neon.mp4")

    before = File.read!(video)
    assert :ok = Audio.attach(video, source)

    assert File.read!(video) == before
    refute has_audio?(video)
  end

  test "origem inexistente: best-effort, não levanta e mantém o vídeo", %{tmp_dir: tmp} do
    video = muted(tmp, "neon.mp4")
    before = File.read!(video)

    assert :ok = Audio.attach(video, Path.join(tmp, "nao-existe.mp4"))
    assert File.read!(video) == before
  end

  defp with_audio(tmp, name) do
    path = Path.join(tmp, name)

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=1:size=32x32:rate=8) ++
          ~w(-f lavfi -i sine=frequency=440:duration=1 -shortest #{path})
      )

    path
  end

  defp muted(tmp, name) do
    path = Path.join(tmp, name)

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=1:size=32x32:rate=8 -an #{path})
      )

    path
  end

  defp has_audio?(path) do
    {out, 0} =
      System.cmd(
        "ffprobe",
        ~w(-v error -select_streams a -show_entries stream=codec_type -of csv=p=0 #{path})
      )

    String.contains?(out, "audio")
  end
end
