defmodule Camerex.Workspace do
  @moduledoc """
  Estado do app em disco, sem banco: cada conversão é uma pasta
  autocontida em `workspace/items/<id>/` com `manifest.json`.
  """

  @spec root() :: Path.t()
  def root, do: Application.fetch_env!(:camerex, :workspace_root)

  @spec items_dir() :: Path.t()
  def items_dir, do: ensure_dir(Path.join(root(), "items"))

  @spec tmp_dir() :: Path.t()
  def tmp_dir, do: ensure_dir(Path.join(root(), "tmp"))

  @doc """
  Slug ASCII do nome original: minúsculo, sem acentos, [a-z0-9-],
  máximo 24 caracteres. Nome inaproveitável (só emoji etc.) vira "item".
  """
  @spec slug(String.t()) :: String.t()
  def slug(original_filename) do
    base =
      original_filename
      |> Path.basename()
      |> Path.rootname()
      |> String.downcase()
      |> String.normalize(:nfd)
      |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 24)
      |> String.trim_trailing("-")

    if base == "", do: "item", else: base
  end

  @doc """
  Id de item: `YYYYMMDD-HHMMSS-<slug>-<preset>-<rand4>` no fuso
  America/Sao_Paulo (contrato §4).
  """
  @spec generate_id(String.t(), String.t()) :: String.t()
  def generate_id(original_filename, preset_id) do
    ts = Calendar.strftime(DateTime.now!("America/Sao_Paulo"), "%Y%m%d-%H%M%S")
    rand4 = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)
    "#{ts}-#{slug(original_filename)}-#{preset_id}-#{rand4}"
  end

  @doc """
  Copia o arquivo de origem para `items/<id>/original.<ext>` e escreve o
  manifest com status "queued". Devolve o id do item.
  """
  @spec create_item(Path.t(), String.t(), :photo | :video, String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def create_item(src_path, original_filename, type, preset_id, params)
      when type in [:photo, :video] and is_map(params) do
    id = generate_id(original_filename, preset_id)
    dir = Path.join(items_dir(), id)
    ext = original_filename |> Path.extname() |> String.downcase()
    original_file = "original#{ext}"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.cp(src_path, Path.join(dir, original_file)) do
      manifest = %{
        "id" => id,
        "type" => Atom.to_string(type),
        "original_filename" => original_filename,
        "original_file" => original_file,
        "output_file" => if(type == :photo, do: "neon.png", else: "neon.mp4"),
        "preset" => preset_id,
        "params" => params,
        "status" => "queued",
        "error" => nil,
        "media" => nil,
        "created_at" => DateTime.now!("America/Sao_Paulo") |> DateTime.to_iso8601(),
        "completed_at" => nil,
        "timings_ms" => %{"total" => nil, "per_frame_avg" => nil}
      }

      write_manifest!(id, manifest)
      {:ok, id}
    else
      {:error, reason} ->
        File.rm_rf(dir)
        {:error, reason}
    end
  end

  @spec manifest(String.t()) :: {:ok, map()} | {:error, :not_found}
  def manifest(id) do
    with {:ok, json} <- File.read(manifest_path(id)),
         {:ok, map} <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> {:error, :not_found}
    end
  end

  @spec update_manifest(String.t(), (map() -> map())) :: {:ok, map()} | {:error, :not_found}
  def update_manifest(id, fun) when is_function(fun, 1) do
    with {:ok, current} <- manifest(id) do
      {:ok, write_manifest!(id, fun.(current))}
    end
  end

  @doc "Manifests de todos os itens válidos, mais recentes primeiro."
  @spec list_items() :: [map()]
  def list_items do
    case File.ls(items_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          case manifest(entry) do
            {:ok, m} -> [m]
            {:error, :not_found} -> []
          end
        end)
        |> Enum.sort_by(& &1["created_at"], :desc)

      {:error, _} ->
        []
    end
  end

  @doc "Apaga a pasta do item. Idempotente."
  @spec delete_item(String.t()) :: :ok
  def delete_item(id) do
    if id in ["", ".", ".."] or Path.basename(id) != id do
      raise ArgumentError, "id de item inválido: #{inspect(id)}"
    end

    File.rm_rf!(Path.join(items_dir(), id))
    :ok
  end

  @spec item_path(String.t(), String.t()) :: Path.t()
  def item_path(id, file), do: Path.join([items_dir(), id, file])

  @spec media_url(String.t(), String.t()) :: String.t()
  def media_url(id, file), do: "/media/items/#{id}/#{file}"

  defp manifest_path(id), do: item_path(id, "manifest.json")

  defp write_manifest!(id, manifest) do
    File.write!(manifest_path(id), Jason.encode!(manifest, pretty: true))
    manifest
  end

  defp ensure_dir(path) do
    File.mkdir_p!(path)
    path
  end
end
