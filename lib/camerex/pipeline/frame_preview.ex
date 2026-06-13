defmodule Camerex.Pipeline.FramePreview do
  @moduledoc """
  Frame central de um vídeo como fonte de prévia: extração com ffmpeg fora
  da camada web. A calibragem ao vivo (`Camerex.Calibration`) parte daqui
  para vídeos.
  """

  alias Camerex.Video.Probe
  alias Camerex.Workspace

  @doc "Frame central do vídeo como tensor RGB — fonte da calibragem ao vivo."
  @spec middle_frame_rgb(Path.t()) :: {:ok, Nx.Tensor.t()} | {:error, term()}
  def middle_frame_rgb(video_path) do
    tmp_png = Path.join(Workspace.tmp_dir(), "calib-#{System.unique_integer([:positive])}.png")
    File.mkdir_p!(Path.dirname(tmp_png))

    try do
      with {:ok, info} <- Probe.probe(video_path),
           :ok <- extract_middle_frame(video_path, info.duration_s / 2, tmp_png) do
        case Evision.imread(tmp_png) do
          %Evision.Mat{} = bgr ->
            {:ok,
             bgr
             |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
             |> Evision.Mat.to_nx(Nx.BinaryBackend)}

          _other ->
            {:error, "não consegui ler o frame extraído"}
        end
      end
    after
      File.rm(tmp_png)
    end
  end

  defp extract_middle_frame(video_path, ss, out_png) do
    args = ["-y", "-v", "error", "-ss", "#{ss}", "-i", video_path, "-frames:v", "1", out_png]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> {:error, "ffmpeg falhou (status #{status}): #{String.trim(out)}"}
    end
  end
end
