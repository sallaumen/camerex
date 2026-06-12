defmodule Camerex.Pipeline.Photo do
  @moduledoc """
  Pipeline de foto (contrato §4): segmentar → maior componente → bordas →
  compor. Puro exceto a chamada ao segmenter configurado em
  `config :camerex, :segmenter`. `run/2` (item do Workspace, neon.png,
  thumbs, manifest) chega na Fase 3.
  """

  alias Camerex.{Mask, Neon}
  alias Camerex.Neon.Palette

  @spec render(Nx.Tensor.t(), keyword()) :: {:ok, Nx.Tensor.t()} | {:error, term()}
  def render(rgb, opts \\ []) do
    preset_id = Keyword.get(opts, :preset, "forro-teal")
    halo = Keyword.get(opts, :halo, 0.6)
    detail = Keyword.get(opts, :detail, 0.5)
    swap_sides = Keyword.get(opts, :swap_sides, false)
    model = Keyword.get(opts, :model, "u2net")

    segmenter = Application.fetch_env!(:camerex, :segmenter)

    with {:ok, preset} <- fetch_preset(preset_id),
         {:ok, raw_mask} <- segmenter.segment(rgb, model: model) do
      mask = Mask.largest_component(raw_mask)

      edges =
        rgb
        |> Neon.trace_edges(mask, detail: detail)
        |> Nx.as_type(:f32)
        |> Nx.divide(255.0)

      opts = compose_opts(preset, mask, halo)
      {:ok, Neon.compose(edges, colors(preset, swap_sides), opts)}
    end
  end

  defp fetch_preset(id) do
    case Palette.get(id) do
      nil -> {:error, {:unknown_preset, id}}
      preset -> {:ok, preset}
    end
  end

  # swap_sides só faz sentido com 2 cores; em mono é ignorado
  defp colors(%{colors: [left, right]}, true), do: [right, left]
  defp colors(%{colors: colors}, _swap), do: colors

  defp compose_opts(%{mode: :duotone}, mask, halo) do
    {h, w} = Nx.shape(mask)
    weights = Neon.duotone_weights(h, w, Neon.mask_median_x(mask), 24)
    [halo: halo, duotone_weights: weights]
  end

  defp compose_opts(%{mode: :mono}, _mask, halo), do: [halo: halo]
end
