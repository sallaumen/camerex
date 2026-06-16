defmodule Camerex.Library.Export do
  @moduledoc """
  Exportação em massa: empacota num único `.zip` os resultados (neon) já
  prontos de uma pasta, pra baixar tudo de uma vez — o passo "preparei o evento
  inteiro, agora levo pro site" sem catar arquivo por arquivo.

  Espelha o irmão `Camerex.Library.Import`. Puro/testável: `entries/1` decide o
  que entra e com que nome; `zip/1` empacota em memória.
  """

  alias Camerex.{Library, Workspace}

  @doc """
  Entradas exportáveis da pasta: itens `"done"` cujo arquivo de saída existe em
  disco, já com um nome amigável e ÚNICO dentro do zip.
  """
  @spec entries(String.t()) :: [%{name: String.t(), path: String.t()}]
  def entries(folder) do
    folder
    |> Library.items_in()
    |> Enum.filter(&done_with_output?/1)
    |> Enum.map(fn item ->
      %{raw_name: export_name(item), path: Workspace.item_path(item["id"], item["output_file"])}
    end)
    |> Enum.filter(&File.exists?(&1.path))
    |> dedupe()
  end

  @doc """
  Zip em memória dos resultados prontos da pasta. `{:error, :empty}` quando não
  há nada exportável (a UI esconde o botão nesse caso, mas a rota é defensiva).
  """
  @spec zip(String.t()) :: {:ok, %{filename: String.t(), data: binary()}} | {:error, :empty}
  def zip(folder) do
    case entries(folder) do
      [] ->
        {:error, :empty}

      entries ->
        files = Enum.map(entries, fn e -> {String.to_charlist(e.name), File.read!(e.path)} end)
        {:ok, {_name, data}} = :zip.create(~c"camerex.zip", files, [:memory])
        {:ok, %{filename: filename(folder), data: data}}
    end
  end

  defp done_with_output?(%{"status" => "done", "output_file" => f}) when is_binary(f), do: true
  defp done_with_output?(_), do: false

  # "forro-laranja.png" + saída ".png" -> "forro-laranja-neon.png"
  defp export_name(item) do
    base = item["original_filename"] |> to_string() |> Path.basename() |> Path.rootname()
    base = if base == "", do: item["id"], else: base
    base <> "-neon" <> Path.extname(item["output_file"])
  end

  # nomes repetidos (mesma mídia de origem) ganham sufixo -2, -3… pra não colidir
  defp dedupe(entries) do
    {out, _seen} =
      Enum.map_reduce(entries, %{}, fn e, seen ->
        count = Map.get(seen, e.raw_name, 0)
        name = if count == 0, do: e.raw_name, else: suffixed(e.raw_name, count + 1)
        {%{name: name, path: e.path}, Map.put(seen, e.raw_name, count + 1)}
      end)

    out
  end

  defp suffixed(name, n), do: Path.rootname(name) <> "-#{n}" <> Path.extname(name)

  defp filename(""), do: "camerex-biblioteca.zip"

  defp filename(folder) do
    slug = folder |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.trim("-")
    "camerex-#{slug}.zip"
  end
end
