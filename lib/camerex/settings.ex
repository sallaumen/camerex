defmodule Camerex.Settings do
  @moduledoc """
  Configurações do usuário persistidas em `workspace/settings.json`
  (ex.: concorrência do pool de jobs). Arquivo corrompido ou ausente é
  tratado como vazio — preferências nunca derrubam o app.
  """

  alias Camerex.Workspace

  @file_name "settings.json"

  @spec get(String.t(), term()) :: term()
  def get(key, default) do
    Map.get(read_all(), key, default)
  end

  @spec put(String.t(), term()) :: :ok
  def put(key, value) do
    settings = Map.put(read_all(), key, value)
    File.write!(path(), Jason.encode!(settings, pretty: true))
    :ok
  end

  defp read_all do
    with {:ok, json} <- File.read(path()),
         {:ok, %{} = map} <- Jason.decode(json) do
      map
    else
      _ -> %{}
    end
  end

  defp path, do: Path.join(Workspace.root(), @file_name)
end
