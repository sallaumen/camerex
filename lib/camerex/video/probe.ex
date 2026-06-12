defmodule Camerex.Video.Probe do
  @moduledoc """
  Metadata de vídeo via ffprobe (saída JSON). Tolerante a containers que
  omitem campos (webm não tem nb_frames nem duração de stream).
  """

  @spec probe(Path.t()) ::
          {:ok,
           %{
             width: pos_integer(),
             height: pos_integer(),
             fps: float(),
             nb_frames: pos_integer() | nil,
             duration_s: float()
           }}
          | {:error, String.t()}
  def probe(path) do
    args = [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=width,height,r_frame_rate,nb_frames,duration",
      "-of",
      "json",
      path
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {out, 0} ->
        parse(out, path)

      {out, status} ->
        {:error,
         "ffprobe falhou (status #{status}) em #{Path.basename(path)}: #{String.trim(out)}"}
    end
  end

  defp parse(json, path) do
    with {:ok, %{"streams" => [stream | _]}} <- Jason.decode(json),
         {:ok, fps} <- parse_fps(stream["r_frame_rate"]),
         {:ok, duration} <- parse_duration(stream, path) do
      {:ok,
       %{
         width: stream["width"],
         height: stream["height"],
         fps: fps,
         nb_frames: parse_int(stream["nb_frames"]),
         duration_s: duration
       }}
    else
      {:error, msg} when is_binary(msg) ->
        {:error, msg}

      _other ->
        {:error, "saída inesperada do ffprobe para #{Path.basename(path)}"}
    end
  end

  defp parse_fps(rate) when is_binary(rate) do
    case String.split(rate, "/") do
      [n] -> fraction_to_float(n, "1", rate)
      [n, d] -> fraction_to_float(n, d, rate)
      _ -> {:error, "r_frame_rate inválido: #{rate}"}
    end
  end

  defp parse_fps(other), do: {:error, "r_frame_rate ausente: #{inspect(other)}"}

  defp fraction_to_float(n, d, rate) do
    with {num, ""} <- Integer.parse(n),
         {den, ""} <- Integer.parse(d),
         true <- den > 0 do
      {:ok, num / den}
    else
      _ -> {:error, "r_frame_rate inválido: #{rate}"}
    end
  end

  # webm: duração de stream ausente → segundo probe pedindo format=duration
  defp parse_duration(stream, path) do
    case parse_float(stream["duration"]) do
      nil -> format_duration(path)
      d -> {:ok, d}
    end
  end

  defp format_duration(path) do
    args = ["-v", "error", "-show_entries", "format=duration", "-of", "json", path]

    with {out, 0} <- System.cmd("ffprobe", args, stderr_to_stdout: true),
         {:ok, %{"format" => %{"duration" => d}}} <- Jason.decode(out),
         dur when is_float(dur) <- parse_float(d) do
      {:ok, dur}
    else
      _ -> {:error, "duração indisponível em #{Path.basename(path)}"}
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int("N/A"), do: nil

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_float(nil), do: nil
  defp parse_float("N/A"), do: nil
  defp parse_float(v) when is_number(v), do: v * 1.0

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end
end
