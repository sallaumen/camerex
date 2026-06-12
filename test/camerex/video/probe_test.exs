defmodule Camerex.Video.ProbeTest do
  use ExUnit.Case, async: true

  alias Camerex.Video.Probe

  setup_all do
    dir = Path.join(System.tmp_dir!(), "camerex-probe-fixtures")
    File.mkdir_p!(dir)

    mp4 = Path.join(dir, "test.mp4")
    ntsc = Path.join(dir, "ntsc.mp4")
    webm = Path.join(dir, "test.webm")
    bad = Path.join(dir, "corrupted.mp4")

    unless File.exists?(mp4) do
      {_, 0} =
        System.cmd(
          "ffmpeg",
          ~w(-y -v error -f lavfi -i testsrc=duration=1:size=64x48:rate=8 #{mp4})
        )
    end

    unless File.exists?(ntsc) do
      {_, 0} =
        System.cmd(
          "ffmpeg",
          ~w(-y -v error -f lavfi -i testsrc=duration=1:size=64x48:rate=30000/1001 #{ntsc})
        )
    end

    unless File.exists?(webm) do
      {_, 0} =
        System.cmd(
          "ffmpeg",
          ~w(-y -v error -f lavfi -i testsrc=duration=1:size=64x48:rate=8 -c:v libvpx #{webm})
        )
    end

    File.write!(bad, "isto não é um vídeo")

    %{mp4: mp4, ntsc: ntsc, webm: webm, bad: bad}
  end

  test "mp4 sintético: width/height/fps/nb_frames/duração", %{mp4: mp4} do
    assert {:ok, info} = Probe.probe(mp4)
    assert info.width == 64
    assert info.height == 48
    assert info.fps == 8.0
    assert info.nb_frames == 8
    assert_in_delta info.duration_s, 1.0, 0.1
  end

  test "r_frame_rate fracionário 30000/1001 vira float", %{ntsc: ntsc} do
    assert {:ok, info} = Probe.probe(ntsc)
    assert_in_delta info.fps, 29.97, 0.01
  end

  test "webm sem nb_frames devolve nil, mas com duração", %{webm: webm} do
    assert {:ok, info} = Probe.probe(webm)
    assert info.nb_frames == nil
    assert info.width == 64
    assert_in_delta info.duration_s, 1.0, 0.15
  end

  test "arquivo corrompido devolve erro legível com o nome do arquivo", %{bad: bad} do
    assert {:error, msg} = Probe.probe(bad)
    assert is_binary(msg)
    assert msg =~ "corrupted.mp4"
  end
end
