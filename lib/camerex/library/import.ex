defmodule Camerex.Library.Import do
  @moduledoc """
  Importação de uma pasta inteira do disco para a biblioteca — sem upload:
  o app escaneia o caminho, copia as mídias para o workspace (biblioteca
  autocontida) e espelha as subpastas reais como pastas virtuais. Itens
  importados nascem com status `"new"` (sem conversão) até serem
  processados em massa.
  """

  alias Camerex.Workspace

  @photo_exts ~w(.jpg .jpeg .png .webp)
  @video_exts ~w(.mp4 .mov .m4v .webm)
  @media_exts @photo_exts ++ @video_exts

  @type media :: %{path: Path.t(), rel_folder: String.t(), size: non_neg_integer()}

  @doc "Escaneia o diretório recursivamente; só mídias aceitas contam."
  @spec scan(Path.t()) ::
          {:ok, %{media: [media()], total_bytes: non_neg_integer()}} | {:error, String.t()}
  def scan(dir) do
    expanded = Path.expand(dir)

    cond do
      not File.exists?(expanded) ->
        {:error, "diretório não encontrado: #{expanded}"}

      not File.dir?(expanded) ->
        {:error, "não é um diretório: #{expanded}"}

      true ->
        media = collect_media(expanded)
        {:ok, %{media: media, total_bytes: Enum.sum_by(media, & &1.size)}}
    end
  end

  @doc """
  Importa o diretório para a biblioteca sob `dest_folder` (`""` = raiz),
  espelhando subpastas. Arquivos não-mídia contam como `skipped`.
  """
  @spec run(Path.t(), String.t()) ::
          {:ok, %{imported: non_neg_integer(), skipped: non_neg_integer(), errors: [String.t()]}}
          | {:error, String.t()}
  def run(dir, dest_folder) do
    with {:ok, %{media: media}} <- scan(dir) do
      skipped = count_non_media(Path.expand(dir))
      results = Enum.map(media, &import_one(&1, dest_folder))
      errors = for {:error, msg} <- results, do: msg

      {:ok, %{imported: Enum.count(results, &(&1 == :ok)), skipped: skipped, errors: errors}}
    end
  end

  defp import_one(%{path: path, rel_folder: rel_folder}, dest_folder) do
    name = Path.basename(path)
    folder = Path.join(dest_folder, rel_folder) |> String.trim("/") |> String.trim(".")

    case Workspace.create_item(path, name, media_type(name), nil, folder: folder) do
      {:ok, _id} -> :ok
      {:error, reason} -> {:error, "#{name}: #{inspect(reason)}"}
    end
  end

  defp collect_media(dir) do
    dir
    |> walk()
    |> Enum.filter(&media?/1)
    |> Enum.map(fn path ->
      %{
        path: path,
        rel_folder: path |> Path.relative_to(dir) |> Path.dirname() |> dot_to_root(),
        size: File.stat!(path).size
      }
    end)
    |> Enum.sort_by(& &1.path)
  end

  defp count_non_media(dir) do
    dir |> walk() |> Enum.reject(&media?/1) |> length()
  end

  defp walk(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)
      if File.dir?(full), do: walk(full), else: [full]
    end)
  end

  defp media?(path), do: String.downcase(Path.extname(path)) in @media_exts

  defp media_type(name) do
    if String.downcase(Path.extname(name)) in @video_exts, do: :video, else: :photo
  end

  defp dot_to_root("."), do: ""
  defp dot_to_root(rel), do: rel
end
