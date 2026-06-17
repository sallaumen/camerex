defmodule Camerex.Video.Audio do
  @moduledoc """
  Reanexa a trilha de áudio do vídeo ORIGINAL no neon. O pipeline decodifica só
  os frames de imagem, então o output sai mudo; como a duração do neon bate com
  a da origem (amostragem a `min(fps, 12)` preserva `frames/fps = duração`), o
  áudio remuxa direto e fica sincronizado — sem reencodar o vídeo (`-c:v copy`).

  Best-effort: origem sem áudio → no-op; falha no remux → mantém o vídeo mudo
  (o áudio é um bônus, não pode derrubar o render). Um passo `System.cmd` só
  (mux de arquivo, não streaming como Encoder/Decoder).
  """

  @doc """
  Remuxa o áudio de `source_path` sobre o vídeo em `video_path` (sobrescreve no
  lugar). Devolve `:ok` sempre — sem áudio ou em caso de falha, o vídeo
  permanece intacto (mudo).
  """
  @spec attach(Path.t(), Path.t()) :: :ok
  def attach(video_path, source_path) do
    if has_audio?(source_path) do
      mux(video_path, source_path)
    else
      :ok
    end
  end

  defp has_audio?(path) do
    args = ~w(-v error -select_streams a -show_entries stream=codec_type -of csv=p=0)

    case System.cmd("ffprobe", args ++ [path], stderr_to_stdout: true) do
      {out, 0} -> String.contains?(out, "audio")
      _ -> false
    end
  end

  defp mux(video_path, source_path) do
    tmp = video_path <> ".muxed.mp4"

    args =
      ~w(-y -v error) ++
        ["-i", video_path, "-i", source_path] ++
        ~w(-map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -movflags +faststart) ++
        [tmp]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} ->
        File.rename!(tmp, video_path)
        :ok

      _ ->
        # mantém o vídeo mudo; áudio é best-effort
        File.rm(tmp)
        :ok
    end
  end
end
