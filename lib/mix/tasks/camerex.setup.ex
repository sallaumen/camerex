defmodule Mix.Tasks.Camerex.Setup do
  @shortdoc "Baixa os modelos ONNX (u2net, u2netp) para priv/models, com verificação MD5"

  @moduledoc """
  Baixa os modelos de segmentação dos releases da rembg e confere o MD5.
  Idempotente: arquivo já presente com MD5 correto é pulado.

      mix camerex.setup
  """

  use Mix.Task

  @requirements ["app.config"]

  # u2net: MD5 do spec §2; u2netp: MD5 extraído de rembg/sessions/u2netp.py
  @models [
    %{
      file: "u2net.onnx",
      url: "https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2net.onnx",
      md5: "60024c5c889badc19c04ad937298a77b"
    },
    %{
      file: "u2netp.onnx",
      url: "https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2netp.onnx",
      md5: "8e83ca70e441ab06c318d82300c84806"
    }
  ]

  @impl Mix.Task
  def run(_args) do
    models_dir = Application.fetch_env!(:camerex, :models_dir)
    File.mkdir_p!(models_dir)
    Enum.each(@models, &ensure_model(&1, models_dir))
    :ok
  end

  defp ensure_model(%{file: file, url: url, md5: md5}, dir) do
    path = Path.join(dir, file)

    if File.exists?(path) and md5_of(path) == md5 do
      Mix.shell().info("ok: #{file} já presente (md5 confere)")
    else
      Mix.shell().info("baixando #{file} (pode demorar alguns minutos) ...")
      download!(url, path)

      case md5_of(path) do
        ^md5 ->
          Mix.shell().info("ok: #{file} baixado (md5 confere)")

        other ->
          File.rm(path)
          Mix.raise("md5 inválido para #{file}: esperado #{md5}, obtido #{other}")
      end
    end
  end

  # -L segue o redirect do GitHub Releases para o CDN; --fail aborta em HTTP >= 400
  defp download!(url, path) do
    args = ["-L", "--fail", "--retry", "3", "-sS", "-o", path, url]

    case System.cmd("curl", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> Mix.raise("download falhou (curl exit #{status}): #{url}\n#{out}")
    end
  end

  # hash em streaming de 2 MiB para não carregar 176 MB em memória
  defp md5_of(path) do
    path
    |> File.stream!(2 * 1024 * 1024)
    |> Enum.reduce(:crypto.hash_init(:md5), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
