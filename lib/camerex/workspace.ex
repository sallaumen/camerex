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

  defp ensure_dir(path) do
    File.mkdir_p!(path)
    path
  end
end
