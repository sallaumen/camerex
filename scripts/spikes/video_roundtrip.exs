# Spike 0.8: roundtrip de vídeo 100% por pipes (contrato §5).
# decode (Exile.stream!) -> chunker -> passthrough -> encode (Exile.Process).
# Rodar: mix run scripts/spikes/video_roundtrip.exs

defmodule VideoRoundtripSpike do
  @in_path Path.expand("exemplos/entrada/clip.mp4")
  @out_path "/tmp/roundtrip.mp4"
  @work_width 640

  def run do
    {:ok, src} = probe(@in_path)

    IO.puts(
      "origem: #{src.width}x#{src.height} @ #{Float.round(src.fps, 3)} fps, " <>
        "#{src.duration_s}s, nb_frames=#{inspect(src.nb_frames)}"
    )

    fps = min(src.fps, 15.0)
    # mesma conta do scale=640:-2 do ffmpeg: largura 640, altura proporcional par
    height = 2 * round(src.height * @work_width / src.width / 2)
    frame_bytes = @work_width * height * 3

    {:ok, enc} =
      Exile.Process.start_link([
        "ffmpeg", "-y", "-v", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", "#{@work_width}x#{height}", "-r", "#{fps}", "-i", "-",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18",
        "-movflags", "+faststart", @out_path
      ])

    counter = :counters.new(1, [])

    n_frames =
      [
        "ffmpeg", "-v", "error", "-i", @in_path,
        "-vf", "fps=#{fps},scale=#{@work_width}:-2",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-"
      ]
      |> Exile.stream!()
      |> Stream.each(fn chunk -> :counters.add(counter, 1, byte_size(chunk)) end)
      |> chunk_frames(frame_bytes)
      |> Enum.reduce(0, fn frame, acc ->
        # passthrough: o frame cru volta direto para o encoder (write tem backpressure)
        :ok = Exile.Process.write(enc, frame)
        acc + 1
      end)

    :ok = Exile.Process.close_stdin(enc)
    {:ok, 0} = Exile.Process.await_exit(enc, 60_000)

    total_bytes = :counters.get(counter, 1)

    check(
      "bytes alinhados a frames",
      rem(total_bytes, frame_bytes) == 0,
      "#{total_bytes} bytes não é múltiplo de #{frame_bytes} — a altura calculada " <>
        "(#{height}) difere da que o scale=-2 do ffmpeg produziu"
    )

    {:ok, out} = probe(@out_path)

    IO.puts(
      "saída : #{out.width}x#{out.height} @ #{Float.round(out.fps, 3)} fps, " <>
        "#{out.duration_s}s, nb_frames=#{inspect(out.nb_frames)}"
    )

    expected_frames = round(src.duration_s * fps)

    check("dimensões pares", rem(out.width, 2) == 0 and rem(out.height, 2) == 0,
      "#{out.width}x#{out.height}")

    check("largura de trabalho 640", out.width == @work_width, "#{out.width}")

    check("fps alvo no arquivo final", abs(out.fps - fps) < 0.05,
      "#{out.fps} != #{fps}")

    check("frames coerentes com o fps alvo", abs(n_frames - expected_frames) <= 2,
      "decodificados #{n_frames}, esperado ~#{expected_frames}")

    check("encoder recebeu todos os frames",
      out.nb_frames == nil or out.nb_frames == n_frames,
      "nb_frames=#{inspect(out.nb_frames)}, escritos #{n_frames}")

    check("duração preservada (±0.2s)",
      abs(out.duration_s - src.duration_s) <= 0.2,
      "saída #{out.duration_s}s vs origem #{src.duration_s}s")

    IO.puts("PASS")
  end

  defp check(label, true, _detail), do: IO.puts("ok: #{label}")

  defp check(label, false, detail) do
    IO.puts("FAIL: #{label} — #{detail}")
    System.halt(1)
  end

  # implementação de referência do contrato §5 — usar tal qual no Decoder (Fase 4)
  defp chunk_frames(byte_stream, frame_bytes) do
    Stream.transform(byte_stream, <<>>, fn chunk, acc ->
      data = acc <> chunk
      n = div(byte_size(data), frame_bytes)
      frames = for i <- 0..(n - 1)//1, do: binary_part(data, i * frame_bytes, frame_bytes)
      rest = binary_part(data, n * frame_bytes, byte_size(data) - n * frame_bytes)
      {frames, rest}
    end)
  end

  # comando ffprobe normativo do contrato §5 (vira Camerex.Video.Probe na Fase 4)
  defp probe(path) do
    {json, 0} =
      System.cmd("ffprobe", [
        "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,nb_frames,duration",
        "-of", "json", path
      ])

    %{"streams" => [s | _]} = Jason.decode!(json)
    [num, den] = String.split(s["r_frame_rate"], "/")
    fps = String.to_integer(num) / String.to_integer(den)

    {:ok,
     %{
       width: s["width"],
       height: s["height"],
       fps: fps,
       nb_frames: parse_int(s["nb_frames"]),
       duration_s: parse_float(s["duration"])
     }}
  end

  defp parse_int(nil), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_float(s) do
    {f, _} = Float.parse(s)
    f
  end
end

VideoRoundtripSpike.run()
