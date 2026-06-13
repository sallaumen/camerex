defmodule Camerex.Video.EncoderTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Camerex.Video.{Encoder, Probe}

  defp synthetic_frame(w, h, i) do
    {h, w, 3} |> Nx.iota(type: :u8) |> Nx.add(i * 7) |> Nx.as_type(:u8)
  end

  test "escreve 8 desenhos on twos e produz mp4 16fps com a mesma duração",
       %{tmp_dir: tmp_dir} do
    out = Path.join(tmp_dir, "out.mp4")

    assert {:ok, enc} = Encoder.open(out, 64, 48, 8, 16)

    for i <- 0..7 do
      assert :ok = Encoder.write_frame(enc, synthetic_frame(64, 48, i))
    end

    assert :ok = Encoder.close(enc)

    # cada desenho segurado 2 frames: 8 desenhos → ~16 frames a 16fps, 1s
    assert {:ok, info} = Probe.probe(out)
    assert info.width == 64
    assert info.height == 48
    assert info.fps == 16.0
    assert_in_delta info.nb_frames, 16, 1
    assert_in_delta info.duration_s, 1.0, 0.1

    {json, 0} =
      System.cmd(
        "ffprobe",
        ~w(-v error -select_streams v:0 -show_entries stream=codec_name,pix_fmt -of json #{out})
      )

    assert %{"streams" => [%{"codec_name" => "h264", "pix_fmt" => "yuv420p"}]} =
             Jason.decode!(json)
  end

  test "frame com shape errado devolve erro sem matar o processo", %{tmp_dir: tmp_dir} do
    out = Path.join(tmp_dir, "shape.mp4")
    assert {:ok, enc} = Encoder.open(out, 64, 48, 8, 16)

    assert {:error, {:bad_frame_shape, {48, 32, 3}}} =
             Encoder.write_frame(enc, Nx.broadcast(Nx.u8(0), {48, 32, 3}))

    assert :ok = Encoder.write_frame(enc, synthetic_frame(64, 48, 0))
    assert :ok = Encoder.close(enc)
  end

  test "status != 0 do ffmpeg vira {:error, _} no close", %{tmp_dir: tmp_dir} do
    out = Path.join(tmp_dir, "odd.mp4")

    # 64x47: libx264 + yuv420p rejeita altura ímpar → ffmpeg sai com status != 0
    assert {:ok, enc} = Encoder.open(out, 64, 47, 8, 16)
    _ = Encoder.write_frame(enc, Nx.broadcast(Nx.u8(128), {47, 64, 3}))

    assert {:error, _} = Encoder.close(enc)
  end
end
