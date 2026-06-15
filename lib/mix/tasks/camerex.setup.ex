defmodule Mix.Tasks.Camerex.Setup do
  @shortdoc "Baixa os modelos ONNX (u2net/u2netp + human parsing) com verificação MD5"

  @moduledoc """
  Baixa os modelos para `priv/models/` (config `:camerex, :models_dir`) com
  verificação de MD5: segmentação (u2net/u2netp) e human parsing
  (segformer_b2_clothes, ~105 MB, para o modo "cor por parte").

      mix camerex.setup            # idempotente: pula o que já está íntegro
      mix camerex.setup --force    # re-baixa tudo

  Termina com um resumo (modelos + ffmpeg) e dica de correção quando falta algo.
  """

  use Mix.Task

  alias Camerex.Doctor

  @impl Mix.Task
  def run(argv) do
    %{force: force} = parse_argv(argv)
    # carrega a config da app sem subir a árvore de supervisão (não há
    # por que iniciar Ortex/Jobs/Endpoint só para baixar arquivos)
    Mix.Task.run("app.config")

    dir = Application.fetch_env!(:camerex, :models_dir)
    File.mkdir_p!(dir)

    results = Enum.map(Doctor.models(), &{&1, ensure_model(&1, dir, force)})
    print_summary(results)

    if Enum.any?(results, &match?({_, {:error, _}}, &1)) do
      Mix.raise("mix camerex.setup terminou com erros — veja o resumo acima")
    end
  end

  @doc false
  @spec parse_argv([String.t()]) :: %{force: boolean()}
  def parse_argv(argv) do
    {opts, _positional, _invalid} = OptionParser.parse(argv, strict: [force: :boolean])
    %{force: Keyword.get(opts, :force, false)}
  end

  @doc false
  @spec action(:ok | :missing | :bad_md5, boolean()) :: :skip | :download
  def action(:ok, false), do: :skip
  def action(:ok, true), do: :download
  def action(:missing, _force), do: :download
  def action(:bad_md5, _force), do: :download

  defp ensure_model(model, dir, force) do
    case action(Doctor.model_status(model, dir), force) do
      :skip ->
        Mix.shell().info("✓ #{model.file} já presente (MD5 ok) — pulando")
        :ok

      :download ->
        download(model, dir)
    end
  end

  defp download(model, dir) do
    dest = Path.join(dir, model.file)
    part = dest <> ".part"
    Mix.shell().info("↓ baixando #{model.file} de #{model.url}")

    status = Mix.shell().cmd(~s(curl -L --fail --progress-bar -o "#{part}" "#{model.url}"))

    if status == 0 do
      verify_and_install(model, part, dest)
    else
      File.rm_rf!(part)
      {:error, "download falhou (curl exit #{status}) — verifique a rede e tente de novo"}
    end
  end

  defp verify_and_install(model, part, dest) do
    case Doctor.md5_file(part) do
      md5 when md5 == model.md5 ->
        File.rename!(part, dest)
        Mix.shell().info("✓ #{model.file} verificado (MD5 #{md5})")
        :ok

      other ->
        File.rm_rf!(part)
        {:error, "MD5 divergente em #{model.file}: esperado #{model.md5}, obtido #{other}"}
    end
  end

  defp print_summary(results) do
    Mix.shell().info("\n— resumo do setup —")

    for {model, result} <- results do
      case result do
        :ok -> Mix.shell().info("modelo #{model.file}: ok")
        {:error, msg} -> Mix.shell().error("modelo #{model.file}: #{msg}")
      end
    end

    case Doctor.check([]).ffmpeg do
      :ok ->
        Mix.shell().info("ffmpeg/ffprobe: ok")

      {:error, msg} ->
        Mix.shell().error("ffmpeg: #{msg}")
        Mix.shell().info("dica: brew install ffmpeg")
    end
  end
end
