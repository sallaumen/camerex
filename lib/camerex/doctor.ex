defmodule Camerex.Doctor do
  @moduledoc """
  Diagnóstico das dependências externas: ffmpeg/ffprobe no PATH e modelos
  ONNX presentes com MD5 correto. Alimenta o banner da galeria e o resumo
  de `mix camerex.setup`.
  """

  @release_base "https://github.com/danielgatis/rembg/releases/download/v0.0.0"

  @models [
    %{
      id: "u2net",
      file: "u2net.onnx",
      md5: "60024c5c889badc19c04ad937298a77b",
      url: "#{@release_base}/u2net.onnx"
    },
    %{
      id: "u2netp",
      file: "u2netp.onnx",
      # valor confirmado na fonte da rembg (sessions/u2netp.py)
      md5: "8e83ca70e441ab06c318d82300c84806",
      url: "#{@release_base}/u2netp.onnx"
    }
  ]

  @type result :: %{
          ffmpeg: :ok | {:error, String.t()},
          models: :ok | {:error, String.t()}
        }

  @doc "Lista normativa dos modelos — fonte única para Doctor e mix camerex.setup."
  @spec models() :: [map()]
  def models, do: @models

  @spec check([map()]) :: result()
  def check(models \\ models()) do
    %{ffmpeg: check_ffmpeg(), models: check_models(models)}
  end

  @spec model_status(map(), Path.t()) :: :ok | :missing | :bad_md5
  def model_status(%{file: file, md5: md5}, dir) do
    path = Path.join(dir, file)

    cond do
      not File.exists?(path) -> :missing
      md5_file(path) != md5 -> :bad_md5
      true -> :ok
    end
  end

  @doc "MD5 em streaming (modelos de até 176 MB; nunca carregar inteiros)."
  @spec md5_file(Path.t()) :: String.t()
  def md5_file(path) do
    path
    |> File.stream!(2_048 * 1_024)
    |> Enum.reduce(:crypto.hash_init(:md5), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp check_ffmpeg do
    case Enum.reject(["ffmpeg", "ffprobe"], &System.find_executable/1) do
      [] -> :ok
      missing -> {:error, Enum.join(missing, " e ") <> " não encontrado(s) no PATH"}
    end
  end

  defp check_models(models) do
    dir = Application.fetch_env!(:camerex, :models_dir)

    case Enum.reject(models, &(model_status(&1, dir) == :ok)) do
      [] -> :ok
      bad -> {:error, "modelos ausentes ou corrompidos: " <> Enum.map_join(bad, ", ", & &1.file)}
    end
  end
end
