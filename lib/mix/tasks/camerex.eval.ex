defmodule Mix.Tasks.Camerex.Eval do
  @shortdoc "Renderiza um acervo de fotos num contact sheet rotulado + métricas"
  @moduledoc """
  Harness de avaliação visual MULTI-FOTO: renderiza um acervo de fotos com um
  conjunto de params (pelo caminho de produção `Photo.render_layered`) e monta um
  CONTACT SHEET rotulado + uma tabela de px por classe semântica — pra provar uma
  mudança em VÁRIAS imagens de uma vez, não numa só.

  O render usa o `RenderParams` (mesma conversão manifest→opts da produção), então
  o que se vê aqui é o que sai no app.

      mix camerex.eval
      mix camerex.eval --params cenario.json   # params (chaves do manifest)
      mix camerex.eval --glob "workspace/items/*aereo*/original.png" --cols 2
      mix camerex.eval --width 320 --out scripts/spikes/out/eval/sheet.png

  Opções:
    * `--glob`   — padrão das fotos (default `workspace/items/*/original.png`)
    * `--params` — caminho de um JSON com params de render (default: neon simples)
    * `--out`    — PNG de saída (default `scripts/spikes/out/eval/sheet.png`)
    * `--width`  — largura de cada tile (default 480 = a prévia ao vivo)
    * `--cols`   — colunas do grid (default 4)

  > ATENÇÃO — o contact sheet é pra OVERVIEW (composição, cor, layout) em VÁRIAS
  > fotos. Detalhe FINO sensível à resolução (escama/textura, espessura de traço)
  > muda com a largura — valide isso na resolução de PRODUÇÃO (prévia 480 OU export
  > nativo), não numa miniatura. O default é 480 (a prévia) justo pra não enganar:
  > um efeito que só aparece em ~360px é artefato de resolução, não de produção.
  """
  use Mix.Task

  alias Camerex.{Eval, Parser, RenderParams}
  alias Camerex.Pipeline.Photo

  @switches [glob: :string, params: :string, out: :string, width: :integer, cols: :integer]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    Mix.Task.run("app.start")

    glob = Keyword.get(opts, :glob, "workspace/items/*/original.png")
    out = Keyword.get(opts, :out, "scripts/spikes/out/eval/sheet.png")
    width = Keyword.get(opts, :width, 480)
    cols = Keyword.get(opts, :cols, 4)
    render_opts = render_opts(opts[:params])

    case Path.wildcard(glob) do
      [] ->
        Mix.shell().error("nenhuma foto casou com #{glob}")

      paths ->
        tiles = Enum.map(paths, &render_tile(&1, width, render_opts))
        write_sheet(out, Eval.contact_sheet(tiles, cols))
        Mix.shell().info("\ncontact sheet (#{length(paths)} fotos) → #{out}")
    end
  end

  # params: JSON do manifest → struct (reusa o parsing da produção); sem arquivo,
  # um neon simples com fundo levemente revelado pra dar contexto.
  defp render_opts(nil), do: to_keyword(%{RenderParams.default() | bg_opacity: 0.25})

  defp render_opts(path) do
    params = path |> File.read!() |> JSON.decode!()
    to_keyword(RenderParams.from_manifest(%{"params" => params}, RenderParams.default()))
  end

  defp to_keyword(%RenderParams{} = p), do: p |> Map.from_struct() |> Map.to_list()

  defp render_tile(path, width, render_opts) do
    rgb = path |> read_rgb() |> fit_width(width)

    tile =
      case Photo.render_layered(rgb, render_opts) do
        {:ok, neon} -> neon
        {:error, _} -> rgb
      end

    print_metrics(label_of(path), rgb)
    label_tile(tile, label_of(path))
  end

  # nome curto do item (a pasta antes de original.png) pro rótulo/tabela
  defp label_of(path), do: path |> Path.dirname() |> Path.basename() |> String.slice(0, 28)

  defp print_metrics(name, rgb) do
    case Parser.parse(rgb) do
      {:ok, labels} ->
        c = Eval.class_counts(labels)

        Mix.shell().info(
          "#{String.pad_trailing(name, 30)} pele=#{c.skin} cabelo=#{c.hair} " <>
            "roupa=#{c.clothing} acess=#{c.accessories} boné=#{c.hat}"
        )

      {:error, _} ->
        Mix.shell().info("#{String.pad_trailing(name, 30)} (parser indisponível)")
    end
  end

  defp read_rgb(path) do
    path
    |> Evision.imread()
    |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  defp fit_width(rgb, width) do
    {h0, w0, 3} = Nx.shape(rgb)

    if w0 == width do
      rgb
    else
      nh = round(h0 * width / w0)

      rgb
      |> Evision.Mat.from_nx_2d()
      |> Evision.resize({width, nh}, interpolation: Evision.Constant.cv_INTER_AREA())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)
    end
  end

  # rótulo branco com contorno preto (legível sobre render claro ou escuro)
  defp label_tile(tile, text) do
    org = {6, 22}
    font = Evision.Constant.cv_FONT_HERSHEY_SIMPLEX()

    tile
    |> Evision.Mat.from_nx_2d()
    |> Evision.putText(text, org, font, 0.5, {0, 0, 0}, thickness: 4)
    |> Evision.putText(text, org, font, 0.5, {255, 255, 255}, thickness: 1)
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  defp write_sheet(out, tensor) do
    File.mkdir_p!(Path.dirname(out))

    mat =
      tensor |> Evision.Mat.from_nx_2d() |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2BGR())

    Evision.imwrite(out, mat)
  end
end
