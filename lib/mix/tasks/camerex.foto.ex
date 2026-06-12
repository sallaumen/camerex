defmodule Mix.Tasks.Camerex.Foto do
  @shortdoc "Converte uma foto em arte neon"

  @moduledoc """
      mix camerex.foto IN OUT [--preset ID] [--halo 0..1] [--detail 0..1]

  Roda o pipeline de foto direto em arquivos, sem criar item na galeria.
  Presets: ver `Camerex.Neon.Palette`. Exige modelos (`mix camerex.setup`).
  """

  use Mix.Task

  alias Camerex.CLI
  alias Camerex.Pipeline

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    case CLI.parse_photo(argv) do
      {:error, msg} ->
        Mix.raise(msg)

      {:ok, %{input: input, output: output, opts: opts}} ->
        opts = Keyword.put_new(opts, :preset, "forro-teal")
        rgb = read_image!(input)
        Mix.shell().info("processando #{input}…")

        case Pipeline.Photo.render(rgb, opts) do
          {:ok, neon} ->
            write_image!(output, neon)
            Mix.shell().info("ok: #{output}")

          {:error, reason} ->
            Mix.raise("falha no pipeline: #{inspect(reason)}")
        end
    end
  end

  # bordas do domínio são RGB: imread devolve BGR → converter já na leitura
  defp read_image!(path) do
    case Evision.imread(path) do
      %Evision.Mat{} = mat ->
        mat
        |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
        |> Evision.Mat.to_nx(Nx.BinaryBackend)

      _other ->
        Mix.raise("não consegui ler a imagem: #{path}")
    end
  end

  defp write_image!(path, rgb_tensor) do
    bgr =
      rgb_tensor
      |> Evision.Mat.from_nx_2d()
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2BGR())

    true = Evision.imwrite(path, bgr)
  end
end
