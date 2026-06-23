defmodule Camerex.Pipeline.LayerRunner do
  @moduledoc """
  Aplica as camadas ATIVAS do `Camerex.Parser.LayerRegistry` sobre os `labels`,
  em ordem (baseline → overlay → destructive), via `Enum.reduce`. Os 3
  orquestradores (photo/video/calibration) delegam aqui — a única diferença é
  como o `fg_provider` é construído (segmenter inline em photo/video vs. cache
  pré-computado na calibration).

  `opts`:
    * `:fg_provider` — `fn {model, kind} -> Nx.Tensor.t() | nil end`. Camadas
      com `fg_spec: :none` (Skin) recebem `fg: nil` no ctx e NÃO chamam o
      provider — o reduce não consulta U²-Net pra elas.
    * `:video?` — boolean (default false). `Hair` desliga o prior espacial no
      vídeo (cabelo se move).
  """

  alias Camerex.Mask
  alias Camerex.Parser.{Hair, LayerContext, LayerRegistry, LayerSpec}

  @doc """
  Constrói o `fg_provider` rodando `segment_fn.(model)` 1× por `{model, kind}`
  distinto exigido pelas camadas ativas — DRY entre photo (segmenter via
  `Application.fetch_env!`) e video (segmenter capturado pra paralelização). O
  `segment_fn` devolve `{:ok, raw}` | `:error`; camadas com `fg_spec: :none`
  (Skin) não entram (sem par a segmentar).
  """
  @spec build_fg_provider([LayerSpec.t()], (String.t() -> {:ok, Nx.Tensor.t()} | :error)) ::
          ({String.t(), :largest | :full} -> Nx.Tensor.t() | nil)
  def build_fg_provider(active, segment_fn) do
    cache =
      active
      |> LayerRegistry.required_segmentations()
      |> Enum.into(%{}, fn {model, kind} -> {{model, kind}, fg_from(segment_fn.(model), kind)} end)

    fn pair -> Map.get(cache, pair) end
  end

  defp fg_from({:ok, raw}, :largest), do: Mask.largest_component(raw)
  defp fg_from({:ok, raw}, :full), do: raw |> Nx.greater(0) |> Nx.multiply(255) |> Nx.as_type(:u8)
  defp fg_from(_other, _kind), do: nil

  @spec run(Nx.Tensor.t(), Nx.Tensor.t(), map(), keyword()) :: Nx.Tensor.t()
  def run(labels, rgb, params, opts) do
    fg_provider = Keyword.fetch!(opts, :fg_provider)
    video? = Keyword.get(opts, :video?, false)
    active = LayerRegistry.active(params)

    Enum.reduce(active, labels, fn %LayerSpec{} = spec, acc ->
      apply_layer(spec, acc, rgb, params, fg_provider, video?)
    end)
  end

  defp apply_layer(spec, labels, rgb, params, fg_provider, video?) do
    color = resolve_color(spec, params)

    if should_run?(spec, labels, color) do
      ctx = %LayerContext{
        rgb: rgb,
        labels: labels,
        fg: fg_for(spec, fg_provider),
        color: color,
        sensitivity: sensitivity(spec, params),
        video?: video?,
        spatial?: not video?
      }

      mask = spec.module.run(ctx)
      spec.module.into_labels(labels, mask)
    else
      labels
    end
  end

  # cor: precedência MODELO (mapa aprendido) > cor única — o Hair tem ambos os
  # params (:model e :color); as outras camadas com cor (:optional) têm só :color.
  # :auto (Skin) e :none (Object) não pegam cor do usuário.
  defp resolve_color(%{color_mode: m}, _params) when m in [:none, :auto], do: nil

  defp resolve_color(spec, params),
    do: param_value(spec, :model, params) || param_value(spec, :color, params)

  defp should_run?(%{color_mode: :required}, _labels, nil), do: false
  defp should_run?(%{gate: :run_when_atr_blind}, labels, _color), do: not Hair.present?(labels)
  defp should_run?(_spec, _labels, _color), do: true

  defp fg_for(%{fg_spec: :none}, _provider), do: nil
  defp fg_for(%{fg_spec: %{model: m, kind: k}}, provider), do: provider.({m, k})

  defp sensitivity(spec, params) do
    case param_value(spec, :slider, params) do
      v when is_number(v) -> v
      _ -> 0.5
    end
  end

  # valor do param de um dado kind no mapa string-keyed, ou nil
  defp param_value(spec, kind, params) do
    case LayerSpec.param_key(spec, kind) do
      nil -> nil
      key -> Map.get(params, to_string(key))
    end
  end
end
