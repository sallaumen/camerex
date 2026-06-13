defmodule Camerex.Video.Encoder do
  @moduledoc """
  Encoda H.264 a partir de frames RGB u8 escritos no stdin de um processo
  ffmpeg persistente (Exile.Process, write com backpressure).
  """

  @opaque t :: %{proc: Exile.Process.t(), width: pos_integer(), height: pos_integer()}

  @doc """
  Abre o encoder na cadência de animação: os frames escritos chegam a
  `drawing_fps` (desenhos/s) e o container sai a `playback_fps` — com
  playback = 2 × drawing, o ffmpeg segura cada desenho por 2 frames
  ("shot on twos", o padrão da animação desenhada à mão).
  """
  @spec open(Path.t(), pos_integer(), pos_integer(), number(), number()) ::
          {:ok, t()} | {:error, term()}
  def open(path, width, height, drawing_fps, playback_fps) do
    cmd = [
      "ffmpeg",
      "-y",
      "-v",
      "error",
      "-f",
      "rawvideo",
      "-pix_fmt",
      "rgb24",
      "-s",
      "#{width}x#{height}",
      "-r",
      "#{drawing_fps}",
      "-i",
      "-",
      "-c:v",
      "libx264",
      "-pix_fmt",
      "yuv420p",
      "-crf",
      "18",
      "-r",
      "#{playback_fps}",
      "-movflags",
      "+faststart",
      path
    ]

    case Exile.Process.start_link(cmd) do
      {:ok, proc} -> {:ok, %{proc: proc, width: width, height: height}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write_frame(t(), Nx.Tensor.t()) :: :ok | {:error, term()}
  def write_frame(%{proc: proc, width: w, height: h}, frame) do
    case Nx.shape(frame) do
      {^h, ^w, 3} -> Exile.Process.write(proc, Nx.to_binary(frame))
      other -> {:error, {:bad_frame_shape, other}}
    end
  end

  @spec close(t()) :: :ok | {:error, term()}
  def close(%{proc: proc}) do
    :ok = Exile.Process.close_stdin(proc)

    # await_exit só devolve {:ok, status} (timeout mata o processo e
    # devolve o status do kill) — não há cláusula de erro
    case Exile.Process.await_exit(proc, 60_000) do
      {:ok, 0} -> :ok
      {:ok, status} -> {:error, "ffmpeg saiu com status #{status}"}
    end
  end
end
