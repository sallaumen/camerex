defmodule Mix.Tasks.Camerex.Video do
  @shortdoc "Converte um vídeo em arte neon"

  @moduledoc """
      mix camerex.video IN OUT [--preset ID]

  Roda o pipeline de vídeo direto em arquivos (sem galeria), com progresso
  no stdout. Exige ffmpeg no PATH e modelos (`mix camerex.setup`).
  """

  use Mix.Task

  alias Camerex.CLI
  alias Camerex.Pipeline

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    case CLI.parse_video(argv) do
      {:error, msg} ->
        Mix.raise(msg)

      {:ok, %{input: input, output: output, opts: opts}} ->
        opts = Keyword.put_new(opts, :preset, "forro-teal")
        progress_cb = fn done, total -> IO.write("\rframe #{done}/#{total}") end

        case Pipeline.Video.render_file(input, output, opts, progress_cb) do
          :ok ->
            IO.write("\n")
            Mix.shell().info("ok: #{output}")

          {:error, reason} ->
            IO.write("\n")
            Mix.raise("falha no pipeline: #{inspect(reason)}")
        end
    end
  end
end
