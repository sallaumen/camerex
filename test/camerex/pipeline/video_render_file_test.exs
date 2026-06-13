defmodule Camerex.Pipeline.VideoRenderFileTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Camerex.Pipeline
  alias Camerex.Video.Probe

  setup %{tmp_dir: tmp} do
    in_path = Path.join(tmp, "in.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=1:size=320x240:rate=10
           -c:v libx264 -pix_fmt yuv420p) ++ [in_path]
      )

    %{in_path: in_path, out_path: Path.join(tmp, "out.mp4")}
  end

  test "gera mp4 640px com dimensões pares, fps alvo e progresso por frame",
       %{in_path: in_path, out_path: out_path} do
    parent = self()
    progress_cb = fn done, total -> send(parent, {:progress, done, total}) end

    assert :ok =
             Pipeline.Video.render_file(
               in_path,
               out_path,
               [preset: "forro-teal", trail: 0.6],
               progress_cb
             )

    assert File.exists?(out_path)

    {:ok, info} = Probe.probe(out_path)
    assert info.width == 640
    assert rem(info.width, 2) == 0 and rem(info.height, 2) == 0
    # origem 10 fps < 12 → 10 desenhos/s on twos: container 20fps, ~1 s
    assert_in_delta info.fps, 20.0, 0.1
    assert_in_delta info.duration_s, 1.0, 0.3

    assert_received {:progress, 1, total}
    assert total == 10
  end

  test "origem rapida e limitada a 12 desenhos por segundo, container 24fps",
       %{tmp_dir: tmp} do
    in_path = Path.join(tmp, "fast.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=1:size=320x240:rate=30
           -c:v libx264 -pix_fmt yuv420p) ++ [in_path]
      )

    out_path = Path.join(tmp, "fast-neon.mp4")

    assert :ok =
             Pipeline.Video.render_file(
               in_path,
               out_path,
               [preset: "forro-teal"],
               fn _done, _total -> :ok end
             )

    {:ok, info} = Probe.probe(out_path)
    assert_in_delta info.fps, 24.0, 0.1
    assert_in_delta info.nb_frames, 24, 2
    assert_in_delta info.duration_s, 1.0, 0.3
  end
end
