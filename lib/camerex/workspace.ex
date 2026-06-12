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

  defp ensure_dir(path) do
    File.mkdir_p!(path)
    path
  end
end
