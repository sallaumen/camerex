# Spike 0.9: ms/frame da segmentação (u2net vs u2netp) + ops Evision do
# trace_edges, sobre 10 frames reais do clip de exemplo a 640px.
# Rodar: mix run scripts/spikes/bench_segmenter.exs

defmodule BenchSegmenterSpike do
  @in_path Path.expand("exemplos/entrada/clip.mp4")
  @work_width 640
  @n_frames 10

  @mean [0.485, 0.456, 0.406]
  @std [0.229, 0.224, 0.225]

  def run do
    frames = load_frames(@in_path, @n_frames)
    IO.puts("frames carregados: #{length(frames)}\n")

    {u2net_avg, u2net_runs} = bench_model("u2net", frames)
    {u2netp_avg, u2netp_runs} = bench_model("u2netp", frames)

    # máscara real (u2net) do 1º frame para o bench das ops Evision
    model = Ortex.load(Path.expand("priv/models/u2net.onnx"))
    [first | _] = frames
    mask = segment(model, first)
    edges_avg = bench_trace_edges(first, mask)

    IO.puts("u2net : #{Float.round(u2net_avg, 1)} ms/frame  " <>
      "runs=#{inspect(Enum.map(u2net_runs, &round/1))}")
    IO.puts("u2netp: #{Float.round(u2netp_avg, 1)} ms/frame  " <>
      "runs=#{inspect(Enum.map(u2netp_runs, &round/1))}")
    IO.puts("trace_edges (Evision): #{Float.round(edges_avg, 1)} ms/frame")
    IO.puts("speedup u2netp vs u2net: #{Float.round(u2net_avg / u2netp_avg, 1)}x")
  end

  defp bench_model(model_id, frames) do
    model = Ortex.load(Path.expand("priv/models/#{model_id}.onnx"))

    times =
      for mat <- frames do
        {micros, _mask} = :timer.tc(fn -> segment(model, mat) end)
        micros / 1000
      end

    # o 1º run paga warm-up do ONNX Runtime — descartado da média
    [_warmup | rest] = times
    {Enum.sum(rest) / length(rest), times}
  end

  defp bench_trace_edges(rgb_mat, mask_tensor) do
    mask_mat = Evision.Mat.from_nx(mask_tensor)

    times =
      for _ <- 0..@n_frames do
        {micros, _} = :timer.tc(fn -> trace_edges(rgb_mat, mask_mat) end)
        micros / 1000
      end

    [_warmup | rest] = times
    Enum.sum(rest) / length(rest)
  end

  # pré/pós idêntico ao spike 0.7 (vira Camerex.Segmenter.U2Net na Fase 1);
  # INTER_AREA no downscale — ver RESULTS.md (descoberta do spike 0.7)
  defp segment(model, rgb_mat) do
    {h, w, 3} = Evision.Mat.shape(rgb_mat)

    input =
      rgb_mat
      |> Evision.resize({320, 320}, interpolation: Evision.Constant.cv_INTER_AREA())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)
      |> Nx.as_type(:f32)
      |> then(fn t -> Nx.divide(t, Nx.max(Nx.reduce_max(t), 1.0e-6)) end)
      |> Nx.subtract(Nx.tensor(@mean))
      |> Nx.divide(Nx.tensor(@std))
      |> Nx.transpose(axes: [2, 0, 1])
      |> Nx.new_axis(0)

    d0 = Ortex.run(model, input) |> elem(0) |> Nx.backend_transfer()
    pred = d0[[0, 0]]
    mn = Nx.reduce_min(pred)
    mx = Nx.reduce_max(pred)

    pred
    |> Nx.subtract(mn)
    |> Nx.divide(Nx.subtract(mx, mn))
    |> Nx.multiply(255.0)
    |> Nx.as_type(:u8)
    |> Evision.Mat.from_nx()
    |> Evision.resize({w, h}, interpolation: Evision.Constant.cv_INTER_LANCZOS4())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.greater(30)
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
  end

  # ops Evision do trace_edges do contrato §4 (canny 60/140 = detail 0.5)
  defp trace_edges(rgb_mat, mask_mat) do
    kernel2 = Evision.Mat.from_nx(Nx.broadcast(Nx.u8(1), {2, 2}))
    kernel3 = Evision.Mat.from_nx(Nx.broadcast(Nx.u8(1), {3, 3}))
    kernel5 = Evision.Mat.from_nx(Nx.broadcast(Nx.u8(1), {5, 5}))
    clahe = Evision.createCLAHE(clipLimit: 3.0, tileGridSize: {8, 8})

    gray =
      rgb_mat
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2GRAY())
      |> then(&Evision.CLAHE.apply(clahe, &1))

    # Evision 0.2.x não expõe cv::bitwise_and/or; para máscaras 0/255,
    # AND == min e OR == max (mesma semântica, mesmo resultado)
    inner =
      gray
      |> Evision.bilateralFilter(9, 60.0, 60.0)
      |> Evision.canny(60, 140)
      |> Evision.min(Evision.erode(mask_mat, kernel5))

    inner
    |> Evision.max(Evision.canny(mask_mat, 50, 150))
    |> Evision.morphologyEx(Evision.Constant.cv_MORPH_CLOSE(), kernel3)
    |> Evision.dilate(kernel2)
  end

  defp load_frames(path, n) do
    {w0, h0} = probe_dims(path)
    height = 2 * round(h0 * @work_width / w0 / 2)
    frame_bytes = @work_width * height * 3

    [
      "ffmpeg", "-v", "error", "-i", path,
      "-vf", "fps=15,scale=#{@work_width}:-2",
      # -frames:v limita no PRODUTOR: Stream.take/2 cortaria o pipe no meio e
      # o ffmpeg morreria com Broken pipe (Exile.stream! levanta AbnormalExit)
      "-frames:v", "#{n}",
      "-f", "rawvideo", "-pix_fmt", "rgb24", "-"
    ]
    |> Exile.stream!()
    |> chunk_frames(frame_bytes)
    |> Enum.map(fn bin ->
      bin
      |> Nx.from_binary(:u8, backend: Nx.BinaryBackend)
      |> Nx.reshape({height, @work_width, 3})
      |> Evision.Mat.from_nx_2d()
    end)
  end

  defp probe_dims(path) do
    {json, 0} =
      System.cmd("ffprobe", [
        "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height", "-of", "json", path
      ])

    %{"streams" => [%{"width" => w, "height" => h} | _]} = Jason.decode!(json)
    {w, h}
  end

  defp chunk_frames(byte_stream, frame_bytes) do
    Stream.transform(byte_stream, <<>>, fn chunk, acc ->
      data = acc <> chunk
      n = div(byte_size(data), frame_bytes)
      frames = for i <- 0..(n - 1)//1, do: binary_part(data, i * frame_bytes, frame_bytes)
      rest = binary_part(data, n * frame_bytes, byte_size(data) - n * frame_bytes)
      {frames, rest}
    end)
  end
end

BenchSegmenterSpike.run()
