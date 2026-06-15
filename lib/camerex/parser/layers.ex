defmodule Camerex.Parser.Layers do
  @moduledoc """
  Agrupa as 18 classes ATR do parser em 4 camadas semânticas (pele, cabelo,
  roupa, acessórios), cada uma com uma cor default, e extrai a máscara binária
  de uma camada suavizando as bordas em escada do upsample (close 5×5).
  """

  alias Camerex.Neon.Palette

  @groups [
    %{key: :skin, label: "pele", ids: [11, 12, 13, 14, 15], default: {255, 170, 120}},
    %{key: :hair, label: "cabelo", ids: [1, 2], default: {255, 90, 30}},
    %{key: :clothing, label: "roupa", ids: [4, 5, 6, 7, 8, 17], default: {43, 196, 178}},
    %{key: :accessories, label: "acessórios", ids: [3, 9, 10, 16], default: {127, 119, 240}}
  ]

  @type group :: %{key: atom(), label: String.t(), ids: [0..17], default: Palette.color()}

  @doc "As 4 camadas semânticas, na ordem de composição (pele → acessórios)."
  @spec groups() :: [group()]
  def groups, do: @groups

  @doc "Cores default por camada, no formato `%{skin: rgb, hair: rgb, ...}`."
  @spec default_colors() :: %{atom() => Palette.color()}
  def default_colors, do: Map.new(@groups, &{&1.key, &1.default})

  @doc """
  Normaliza cores por camada vindas do manifest/UI (`%{"skin" => [r,g,b]}` ou
  `%{skin: {r,g,b}}`) para `%{atom => {r,g,b}}`, mescladas sobre os defaults.
  `nil` devolve os defaults.
  """
  @spec normalize_colors(map() | nil) :: %{atom() => Palette.color()}
  def normalize_colors(nil), do: default_colors()

  def normalize_colors(map) when is_map(map) do
    parsed = Map.new(map, fn {k, v} -> {to_key(k), to_color(v)} end)
    Map.merge(default_colors(), parsed)
  end

  defp to_key(k) when is_atom(k), do: k
  defp to_key(k) when is_binary(k), do: String.to_existing_atom(k)
  defp to_color({r, g, b}), do: {r, g, b}
  defp to_color([r, g, b]), do: {r, g, b}

  @doc """
  Máscara u8 `{h, w}` 0|255 dos pixels cujo rótulo está em `ids`, com close
  morfológico 5×5 para suavizar as bordas em escada deixadas pelo upsample.
  """
  @spec mask(Nx.Tensor.t(), [0..17]) :: Nx.Tensor.t()
  def mask(labels, ids) do
    ids
    |> Enum.reduce(Nx.broadcast(Nx.u8(0), Nx.shape(labels)), fn id, acc ->
      Nx.logical_or(acc, Nx.equal(labels, id))
    end)
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
    |> Evision.Mat.from_nx()
    |> Evision.morphologyEx(Evision.Constant.cv_MORPH_CLOSE(), kernel(5))
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  defp kernel(s), do: Evision.Mat.from_nx(Nx.broadcast(Nx.u8(1), {s, s}))
end
