defmodule Camerex.Pipeline.FramePreview do
  @moduledoc """
  Prévia de 1 frame para vídeo: extrai o frame central com ffmpeg, roda o
  pipeline de foto nele e devolve um data URL PNG pronto para `<img src>`.
  Mantém o trabalho pesado (ffmpeg/Evision) fora da camada web.
  """

  alias Camerex.Pipeline.Photo
  alias Camerex.Video.Probe
  alias Camerex.Workspace

  @doc """
  Gera a prévia neon do frame central de `video_path`.

  `opts` são os mesmos de `Camerex.Pipeline.Photo.render/2` (`:preset`,
  `:halo`, `:detail`, `:swap_sides`, `:model`). O PNG intermediário vive em
  `Workspace.tmp_dir/0` e é removido sempre, mesmo em erro.
  """
  @spec data_url(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def data_url(video_path, opts) do
    tmp_png = Path.join(Workspace.tmp_dir(), "preview-#{System.unique_integer([:positive])}.png")
    File.mkdir_p!(Path.dirname(tmp_png))

    try do
      with {:ok, info} <- Probe.probe(video_path),
           :ok <- extract_middle_frame(video_path, info.duration_s / 2, tmp_png) do
        render_frame(tmp_png, opts)
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

  defp render_frame(png_path, opts) do
    rgb =
      png_path
      |> Evision.imread()
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)

    with {:ok, neon} <- Photo.render(rgb, opts) do
      mat =
        neon |> Evision.Mat.from_nx_2d() |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2BGR())

      case Evision.imencode(".png", mat) do
        bin when is_binary(bin) -> {:ok, "data:image/png;base64," <> Base.encode64(bin)}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
