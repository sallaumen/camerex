defmodule Camerex.Neon.Palette do
  @moduledoc """
  Presets de cor do neon (contrato §4). Cores em RGB; nos duotones a lista
  é `[cor_esquerda, cor_direita]` e a UI oferece `swap_sides`.
  """

  @type color :: {0..255, 0..255, 0..255}
  @type preset :: %{
          id: String.t(),
          name: String.t(),
          mode: :mono | :duotone,
          colors: [color()]
        }

  @presets [
    %{id: "forro-laranja", name: "Forró Laranja", mode: :mono, colors: [{255, 138, 92}]},
    %{id: "forro-teal", name: "Forró Teal", mode: :mono, colors: [{43, 196, 178}]},
    %{
      id: "forro-duotone",
      name: "Forró Duotone",
      mode: :duotone,
      colors: [{255, 138, 92}, {43, 196, 178}]
    },
    %{id: "pulp", name: "Pulp", mode: :duotone, colors: [{177, 74, 237}, {74, 155, 237}]},
    %{id: "miami", name: "Miami", mode: :duotone, colors: [{255, 46, 151}, {0, 194, 255}]},
    %{id: "ouro", name: "Ouro", mode: :mono, colors: [{255, 209, 102}]}
  ]

  @spec all() :: [preset()]
  def all, do: @presets

  @spec get(String.t()) :: preset() | nil
  def get(id), do: Enum.find(@presets, &(&1.id == id))

  @doc "Cor RGB → string hex CSS (#RRGGBB) para estilos inline dos swatches."
  @spec hex(color()) :: String.t()
  def hex({r, g, b}) do
    "#" <>
      Enum.map_join([r, g, b], fn channel ->
        channel |> Integer.to_string(16) |> String.pad_leading(2, "0")
      end)
  end
end
