defmodule Camerex.UserPresets do
  @moduledoc """
  Presets de conversão salvos pelo usuário (nome + preset de cor + sliders),
  persistidos em `workspace/user_presets.json`. Arquivo corrompido é tratado
  como vazio — preferências nunca derrubam o app.
  """

  alias Camerex.Neon.Palette
  alias Camerex.Workspace

  @file_name "user_presets.json"
  @models ~w(u2net u2netp)
  # presets antigos guardavam os params como chaves planas no topo (sem o
  # sub-mapa "params"); este é o conjunto que aqueles tinham, p/ fallback
  @legacy_keys ~w(halo trail detail swap_sides model)

  @type preset :: %{String.t() => term()}

  @spec all() :: [preset()]
  def all do
    with {:ok, json} <- File.read(path()),
         {:ok, list} when is_list(list) <- Jason.decode(json) do
      list
    else
      _ -> []
    end
  end

  @spec get(String.t()) :: preset() | nil
  def get(id), do: Enum.find(all(), &(&1["id"] == id))

  @doc "Upsert por nome (id = slug do nome). Valida antes de persistir."
  @spec save(map()) :: {:ok, preset()} | {:error, String.t()}
  def save(attrs) do
    with {:ok, preset} <- validate(attrs) do
      rest = Enum.reject(all(), &(&1["id"] == preset["id"]))
      write!([preset | rest] |> Enum.sort_by(& &1["name"]))
      {:ok, preset}
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(id) do
    all() |> Enum.reject(&(&1["id"] == id)) |> write!()
    :ok
  end

  @doc "Mapa de params de conversão (formato do manifest §3) de um preset salvo."
  @spec params(preset()) :: %{String.t() => term()}
  def params(%{"params" => params}) when is_map(params), do: params
  # presets antigos (chaves planas no topo, sem o sub-mapa "params")
  def params(preset), do: Map.take(preset, @legacy_keys)

  defp validate(attrs) do
    name = attrs |> Map.get("name", "") |> String.trim()

    cond do
      name == "" ->
        {:error, "nome do preset não pode ser vazio"}

      Palette.get(attrs["preset"]) == nil ->
        {:error, "preset de cor desconhecido: #{inspect(attrs["preset"])}"}

      not in_range?(attrs["halo"], 0.0, 1.0) ->
        {:error, "halo fora de [0, 1]"}

      not in_range?(attrs["trail"], 0.0, 0.95) ->
        {:error, "trail fora de [0, 0.95]"}

      not in_range?(attrs["detail"], 0.0, 1.0) ->
        {:error, "detail fora de [0, 1]"}

      attrs["model"] not in @models ->
        {:error, "model deve ser um de: #{Enum.join(@models, ", ")}"}

      true ->
        {:ok,
         %{
           "id" => Workspace.slug(name),
           "name" => name,
           "preset" => attrs["preset"],
           # guarda o mapa de params INTEIRO (genérico): params novos (cor, fundo,
           # objeto, preenchimento, chão…) entram sozinhos, sem listar campo a
           # campo aqui — era exatamente o que deixava preset salvo pra trás.
           "params" => Map.drop(attrs, ["id", "name", "preset"])
         }}
    end
  end

  defp in_range?(value, lo, hi), do: is_number(value) and value >= lo and value <= hi

  defp write!(list), do: File.write!(path(), Jason.encode!(list, pretty: true))

  defp path, do: Path.join(Workspace.root(), @file_name)
end
