defmodule Camerex.Library.ExportTest do
  use Camerex.WorkspaceCase

  alias Camerex.Library.Export
  alias Camerex.Workspace

  # item "done" com um arquivo de saída REAL no disco, na pasta dada
  defp done_item!(tmp, folder, bytes) do
    id = create_photo_item!(tmp, %{status: "done"})

    {:ok, _} =
      Workspace.update_manifest(id, fn m ->
        Map.merge(m, %{"output_file" => "neon.png", "folder" => folder})
      end)

    File.write!(Workspace.item_path(id, "neon.png"), bytes)
    id
  end

  test "zip/1 empacota só os done com saída, com nomes amigáveis e únicos", %{tmp: tmp} do
    done_item!(tmp, "evento", "AAA")
    done_item!(tmp, "evento", "BBB")

    # um item na fila não entra no export
    queued = create_photo_item!(tmp, %{status: "queued"})
    {:ok, _} = Workspace.update_manifest(queued, &Map.put(&1, "folder", "evento"))

    {:ok, %{filename: filename, data: data}} = Export.zip("evento")
    assert filename == "camerex-evento.zip"

    {:ok, files} = :zip.unzip(data, [:memory])
    names = Enum.map(files, fn {n, _} -> to_string(n) end)
    bins = Enum.map(files, fn {_, b} -> b end)

    # 2 arquivos (o queued ficou de fora), nomes derivados de "fonte.png" e
    # deduplicados, com o conteúdo real do disco dentro
    assert length(files) == 2
    assert "fonte-neon.png" in names
    assert "fonte-neon-2.png" in names
    assert "AAA" in bins and "BBB" in bins
  end

  test "zip/1 sem resultados prontos -> {:error, :empty}", %{tmp: tmp} do
    create_photo_item!(tmp, %{status: "queued"})
    assert Export.zip("sem-resultados") == {:error, :empty}
  end
end
