defmodule Camerex.Library do
  @moduledoc """
  Organização da biblioteca: pastas virtuais (metadado `folder` do manifest,
  pastas vazias registradas em `workspace/folders.json`) e operações em
  massa sobre itens (mover, apagar, duplicar, processar).
  """

  alias Camerex.{Jobs, Workspace}

  @folders_file "folders.json"
  @busy_statuses ~w(processing queued)
  # mantém em sincronia com panel_params_for/2 da LibraryLive (tudo que o
  # render lê do manifest); sem isso, reprocessar perde os ajustes novos
  @param_keys ~w(halo bloom chroma trail detail swap_sides model
                 layered layer_colors fill fill_opacity floor glow spread)

  defdelegate normalize_folder(path), to: Workspace

  @doc """
  Visão completa da biblioteca para uma pasta com UM único scan do disco:
  itens diretos da pasta, árvore com contagens e total de itens na raiz.
  É o que a UI usa a cada recarga — `tree/0` + 2× `items_in/1` fariam o
  mesmo com três varreduras de manifests.
  """
  @spec snapshot(String.t()) :: %{
          items: [map()],
          tree: [%{path: String.t(), count: non_neg_integer()}],
          root_count: non_neg_integer()
        }
  def snapshot(folder) do
    all = Workspace.list_items()

    %{
      items: Enum.filter(all, &(&1["folder"] == folder)),
      tree: tree_from(all),
      root_count: Enum.count(all, &(&1["folder"] == ""))
    }
  end

  @doc """
  Pastas da biblioteca (sem a raiz), ordenadas, com contagem de itens
  diretos. Une as registradas em `folders.json`, as referenciadas por itens
  e os ancestrais implícitos (um item em `a/b` faz `a` existir).
  """
  @spec tree() :: [%{path: String.t(), count: non_neg_integer()}]
  def tree, do: tree_from(Workspace.list_items())

  @doc "Itens cuja pasta é exatamente `folder`, mais recentes primeiro."
  @spec items_in(String.t()) :: [map()]
  def items_in(folder) do
    Enum.filter(Workspace.list_items(), &(&1["folder"] == folder))
  end

  @spec create_folder(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def create_folder(path) do
    case normalize_folder(path) do
      {:ok, ""} ->
        {:error, "nome de pasta vazio"}

      {:ok, folder} ->
        register_folder(folder)
        {:ok, folder}

      :error ->
        {:error, "nome de pasta inválido"}
    end
  end

  @doc "Remove a pasta do registro — apenas se não tiver itens nem subpastas."
  @spec delete_folder(String.t()) :: :ok | {:error, :not_empty}
  def delete_folder(folder) do
    if folder_empty?(folder) do
      folder
      |> List.wrap()
      |> then(fn to_remove -> Enum.reject(registered_folders(), &(&1 in to_remove)) end)
      |> write_folders!()

      :ok
    else
      {:error, :not_empty}
    end
  end

  @doc "Move itens para a pasta (normalizada; registrada se nova)."
  @spec move_items([String.t()], String.t()) :: :ok | {:error, String.t()}
  def move_items(ids, folder_input) do
    case normalize_folder(folder_input) do
      {:ok, folder} ->
        if folder != "", do: register_folder(folder)
        Enum.each(ids, &Workspace.update_manifest(&1, fn m -> Map.put(m, "folder", folder) end))
        :ok

      :error ->
        {:error, "nome de pasta inválido"}
    end
  end

  @spec delete_items([String.t()]) :: :ok
  def delete_items(ids) do
    Enum.each(ids, &Workspace.delete_item/1)
    :ok
  end

  @doc "Cria um item novo (status \"new\") copiando o original, na mesma pasta."
  @spec duplicate_item(String.t()) :: {:ok, String.t()} | {:error, term()}
  def duplicate_item(id) do
    with {:ok, manifest} <- Workspace.manifest(id) do
      Workspace.create_item(
        Workspace.item_path(id, manifest["original_file"]),
        manifest["original_filename"],
        String.to_existing_atom(manifest["type"]),
        nil,
        nil,
        folder: manifest["folder"]
      )
    end
  end

  @doc """
  Aplica os params (com `"preset"`) aos itens e enfileira — itens já em
  processamento/fila são pulados. Devolve `%{enqueued: n, skipped: n}`.
  """
  @spec process_items([String.t()], map()) :: %{
          enqueued: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def process_items(ids, params) do
    results = Enum.map(ids, &process_item(&1, params))

    %{
      enqueued: Enum.count(results, &(&1 == :enqueued)),
      skipped: Enum.count(results, &(&1 == :skipped))
    }
  end

  defp process_item(id, params) do
    case Workspace.manifest(id) do
      {:ok, %{"status" => status}} when status in @busy_statuses ->
        :skipped

      {:ok, manifest} ->
        enqueue_with_params(manifest, params)
        :enqueued

      {:error, :not_found} ->
        :skipped
    end
  end

  defp enqueue_with_params(manifest, params) do
    {:ok, _} =
      Workspace.update_manifest(manifest["id"], fn m ->
        Map.merge(m, %{
          "preset" => params["preset"],
          "params" => Map.take(params, @param_keys),
          "status" => "queued",
          "error" => nil,
          "output_file" => Workspace.default_output(String.to_existing_atom(m["type"]))
        })
      end)

    :ok = Jobs.enqueue(manifest["id"])
  end

  defp tree_from(items) do
    counts = Enum.frequencies_by(items, & &1["folder"])

    item_folders = counts |> Map.keys() |> Enum.reject(&(&1 == ""))

    (registered_folders() ++ item_folders)
    |> Enum.flat_map(&with_ancestors/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{path: &1, count: Map.get(counts, &1, 0)})
  end

  defp folder_empty?(folder) do
    prefix = folder <> "/"

    no_items? =
      Enum.all?(Workspace.list_items(), fn item ->
        item["folder"] != folder and not String.starts_with?(item["folder"], prefix)
      end)

    no_subfolders? = not Enum.any?(registered_folders(), &String.starts_with?(&1, prefix))

    no_items? and no_subfolders?
  end

  defp with_ancestors(folder) do
    folder
    |> String.split("/")
    |> Enum.scan(&Path.join(&2, &1))
  end

  defp register_folder(folder) do
    [folder | registered_folders()] |> Enum.uniq() |> Enum.sort() |> write_folders!()
  end

  defp registered_folders do
    with {:ok, json} <- File.read(folders_path()),
         {:ok, list} when is_list(list) <- Jason.decode(json) do
      Enum.filter(list, &is_binary/1)
    else
      _ -> []
    end
  end

  defp write_folders!(folders),
    do: File.write!(folders_path(), Jason.encode!(folders, pretty: true))

  defp folders_path, do: Path.join(Workspace.root(), @folders_file)
end
