defmodule Camerex.ColorJSON do
  @moduledoc """
  Serialização e parse das cores por camada (parte do corpo) de/para um JSON hex
  legível, mesclando sobre os defaults dos grupos. Funções PURAS (sem socket) — a
  UI (modal "cores por parte (JSON)") delega aqui, e dá pra testar sem montar
  LiveView. Aceita `"#RRGGBB"` ou `[r, g, b]`; ignora chaves desconhecidas.
  """
  alias Camerex.Parser.Layers

  @doc """
  Cores atuais (`%{atom => {r,g,b}}`) -> JSON hex ORDENADO pelos grupos (legível
  para editar na modal). Cores ausentes caem no default do grupo.
  """
  def to_json(colors) do
    body =
      Enum.map_join(Layers.groups(), ",\n", fn %{key: key, default: default} ->
        hex = colors |> Map.get(key, default) |> Layers.hex()
        ~s(  "#{key}": "#{hex}")
      end)

    "{\n" <> body <> "\n}"
  end

  @doc """
  JSON colado -> `{:ok, %{atom => {r,g,b}}}` mesclado sobre os defaults, ou
  `{:error, msg legível}`. Aceita `"#RRGGBB"` ou `[r,g,b]`; ignora chaves
  desconhecidas; cor malformada vira erro legível.
  """
  def parse(json) do
    case JSON.decode(json) do
      {:ok, map} when is_map(map) -> build_layer_colors(map)
      {:ok, _other} -> {:error, ~s(o JSON precisa ser um objeto, ex: {"roupa": "#2BC4B2"})}
      {:error, _} -> {:error, "JSON inválido — confira aspas, vírgulas e chaves { }"}
    end
  end

  defp build_layer_colors(map) do
    known = Map.new(Layers.groups(), fn g -> {Atom.to_string(g.key), g.key} end)

    Enum.reduce_while(map, {:ok, Layers.default_colors()}, fn {raw_key, raw_val}, {:ok, acc} ->
      case {Map.get(known, raw_key), json_color(raw_val)} do
        {nil, _} ->
          {:cont, {:ok, acc}}

        {key, {:ok, rgb}} ->
          {:cont, {:ok, Map.put(acc, key, rgb)}}

        {_key, :error} ->
          {:halt, {:error, ~s(cor inválida em "#{raw_key}": use "#RRGGBB" ou [r,g,b])}}
      end
    end)
  end

  defp json_color("#" <> _ = hex) do
    if String.match?(hex, ~r/^#[0-9a-fA-F]{6}$/), do: {:ok, hex_to_rgb(hex)}, else: :error
  end

  defp json_color([r, g, b])
       when is_integer(r) and is_integer(g) and is_integer(b) and
              r in 0..255 and g in 0..255 and b in 0..255 do
    {:ok, {r, g, b}}
  end

  defp json_color(_), do: :error

  defp hex_to_rgb("#" <> <<r::binary-2, g::binary-2, b::binary-2>>) do
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end
end
