defmodule Camerex.Video.Decoder do
  @moduledoc """
  Decodifica vídeo em stream lazy de tensores RGB u8 via ffmpeg
  (rawvideo rgb24 no stdout, lido por Exile.stream!). Memória O(1 frame).
  O ffmpeg aplica `-vf "fps=<fps>,scale=<w>:-2"`; o caller informa o height
  resultante (calcule com `target_height/3`) para o fatiamento dos bytes.
  Falha do ffmpeg no meio do stream levanta exceção do Exile — o Task do
  job morre e Camerex.Jobs marca o manifest como failed (contrato §4).
  """

  @spec stream!(Path.t(), %{width: pos_integer(), height: pos_integer(), fps: number()}) ::
          Enumerable.t()
  def stream!(path, %{width: width, height: height, fps: fps}) do
    frame_bytes = width * height * 3

    [
      "ffmpeg",
      "-v",
      "error",
      "-i",
      path,
      "-vf",
      "fps=#{fps},scale=#{width}:-2",
      "-f",
      "rawvideo",
      "-pix_fmt",
      "rgb24",
      "-"
    ]
    |> Exile.stream!()
    |> chunk_frames(frame_bytes)
    |> Stream.map(fn bin ->
      bin |> Nx.from_binary(:u8) |> Nx.reshape({height, width, 3})
    end)
  end

  @doc """
  Altura que o ffmpeg escolhe para `scale=<target_w>:-2`: proporcional ao
  input e divisível por 2. Espelha o av_rescale do ffmpeg
  (`round(target_w * h0 / (w0 * 2)) * 2` — par mais próximo).
  """
  @spec target_height(pos_integer(), pos_integer(), pos_integer()) :: pos_integer()
  def target_height(width0, height0, target_w) do
    round(target_w * height0 / (width0 * 2)) * 2
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
