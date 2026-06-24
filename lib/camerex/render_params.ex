defmodule Camerex.RenderParams do
  @moduledoc """
  Reúne num struct os controles de render do painel de conversão (princípio
  *Data*): cores por camada, composição (halo/bloom/detalhe), fundo,
  preenchimento, objeto, chão e rastro.

  Concentra o que antes era plumbing repetido em 4 funções da `LibraryLive` (e
  que cada controle novo obrigava a tocar em todas): parsing do `<form>`,
  leitura dos params salvos no item e serialização pro manifest. Tudo PURO
  (sem socket/IO):

    * `default/0` — valores iniciais.
    * `from_form/2` — strings do formulário (phx-change) → struct, `current`
      como fallback dos sliders.
    * `from_manifest/2` — params salvos no item (reprocesso) → struct.
    * `to_manifest/1` — struct → mapa string-keyed pro manifest (sem `model`,
      que é escolha de pipeline e fica com o chamador).

  Adicionar um controle = um campo aqui (+ a lista certa) e o input no template.
  """

  alias Camerex.Parser.{LayerRegistry, Layers}

  # params de RENDER (não-camada): nunca mudam ao adicionar uma camada.
  @render_sliders ~w(halo bloom trail detail bg_opacity bg_blur fill_color fill_texture glow spread)a
  @render_booleans ~w(transparent_bg fill floor)a

  # params das CAMADAS: DERIVADOS do LayerRegistry por kind — FONTE ÚNICA. Some o
  # fan-out de listas à mão (era a causa do bug Skin/hair_model inalcançável);
  # adicionar uma camada não toca este arquivo.
  @layer_params LayerRegistry.all() |> Enum.flat_map(& &1.params)
  @layer_bools for %{key: k, kind: :bool} <- @layer_params, do: k
  @layer_sliders for %{key: k, kind: :slider} <- @layer_params, do: k
  @layer_color_keys for %{key: k, kind: :color} <- @layer_params, do: k
  @layer_model_keys for %{key: k, kind: :model} <- @layer_params, do: k
  @layer_defaults for %{key: k, default: d} <- @layer_params, do: {k, d}

  # sliders viram float (parse com fallback); booleanos vêm de `== "true"`
  @sliders @render_sliders ++ @layer_sliders
  @booleans @render_booleans ++ @layer_bools

  @type rgb :: {0..255, 0..255, 0..255}
  @type t :: %__MODULE__{
          layer_colors: %{atom() => rgb()},
          halo: float(),
          bloom: float(),
          trail: float(),
          detail: float(),
          bg_opacity: float(),
          bg_blur: float(),
          fill_color: float(),
          fill_texture: float(),
          glow: float(),
          spread: float(),
          transparent_bg: boolean(),
          fill: boolean(),
          floor: boolean(),
          # params de camada (derivados do LayerRegistry; cor = pista de detecção
          # na foto, model = mapa aprendido por região via eyedropper)
          detect_object: boolean(),
          detect_aerial: boolean(),
          aerial_color: rgb(),
          aerial_sensitivity: float(),
          detect_hair: boolean(),
          hair_color: rgb(),
          hair_model: map() | nil,
          hair_sensitivity: float(),
          detect_skin: boolean(),
          skin_sensitivity: float()
        }

  # campos de RENDER (literais) + campos de CAMADA (derivados do catálogo)
  @render_defaults [
    layer_colors: %{},
    halo: 0.6,
    bloom: 0.4,
    trail: 0.7,
    detail: 0.5,
    bg_opacity: 0.0,
    bg_blur: 0.0,
    fill_color: 0.45,
    fill_texture: 0.15,
    glow: 0.85,
    spread: 0.5,
    transparent_bg: false,
    fill: false,
    floor: false
  ]

  defstruct @render_defaults ++ @layer_defaults

  @spec default() :: t()
  def default, do: %__MODULE__{layer_colors: Layers.default_colors()}

  @doc "Strings do `<form>` (phx-change \"validate\") → struct; mantém `current` onde faltar."
  @spec from_form(map(), t()) :: t()
  def from_form(form, %__MODULE__{} = current) do
    @sliders
    |> Map.new(fn k -> {k, slider(form[to_string(k)], Map.fetch!(current, k))} end)
    |> Map.merge(Map.new(@booleans, fn k -> {k, form[to_string(k)] == "true"} end))
    |> Map.put(:layer_colors, merge_form_colors(form, current.layer_colors))
    |> put_layer_colors_from_form(form, current)
    |> then(&struct(current, &1))

    # params :model (hair_model) NÃO vêm do <form> — são do eyedropper/região;
    # `struct(current, …)` preserva o atual por não estarem nas mudanças.
  end

  @doc "Params salvos no item (reprocesso) → struct; `current` é fallback dos sliders."
  @spec from_manifest(map(), t()) :: t()
  def from_manifest(%{"params" => p}, %__MODULE__{} = current) when is_map(p) do
    @sliders
    |> Map.new(fn k -> {k, p[to_string(k)] || Map.fetch!(current, k)} end)
    |> Map.merge(Map.new(@booleans, fn k -> {k, p[to_string(k)] || false} end))
    |> Map.put(:layer_colors, Layers.normalize_colors(p["layer_colors"]))
    |> put_layer_colors_from_manifest(p, current)
    |> put_layer_models_from_manifest(p, current)
    |> then(&struct(current, &1))
  end

  def from_manifest(_item, %__MODULE__{} = current), do: current

  @doc "Struct → mapa string-keyed do manifest (sem `model` de pipeline, que o chamador acrescenta)."
  @spec to_manifest(t()) :: %{String.t() => term()}
  def to_manifest(%__MODULE__{} = p) do
    (@sliders ++ @booleans)
    |> Map.new(fn k -> {to_string(k), Map.fetch!(p, k)} end)
    |> Map.put("layer_colors", serialize_colors(p.layer_colors))
    |> put_layer_colors_to_manifest(p)
    |> put_layer_models_to_manifest(p)
  end

  # ── params de camada derivados do catálogo (cor e model), por kind ──
  defp put_layer_colors_from_form(acc, form, current) do
    Enum.reduce(@layer_color_keys, acc, fn k, a ->
      Map.put(a, k, form_rgb(form[to_string(k)], Map.fetch!(current, k)))
    end)
  end

  defp put_layer_colors_from_manifest(acc, p, current) do
    Enum.reduce(@layer_color_keys, acc, fn k, a ->
      Map.put(a, k, list_rgb(p[to_string(k)], Map.fetch!(current, k)))
    end)
  end

  defp put_layer_models_from_manifest(acc, p, current) do
    Enum.reduce(@layer_model_keys, acc, fn k, a ->
      Map.put(a, k, p[to_string(k)] || Map.fetch!(current, k))
    end)
  end

  defp put_layer_colors_to_manifest(acc, p) do
    Enum.reduce(@layer_color_keys, acc, fn k, a ->
      Map.put(a, to_string(k), Tuple.to_list(Map.fetch!(p, k)))
    end)
  end

  defp put_layer_models_to_manifest(acc, p) do
    Enum.reduce(@layer_model_keys, acc, fn k, a ->
      Map.put(a, to_string(k), Map.fetch!(p, k))
    end)
  end

  # cor única (não-camada): hex do <input type=color> / lista do manifest → {r,g,b}
  defp form_rgb("#" <> _ = hex, _fallback), do: hex_to_rgb(hex)
  defp form_rgb(_other, fallback), do: fallback

  defp list_rgb([r, g, b], _fallback), do: {r, g, b}
  defp list_rgb(_other, fallback), do: fallback

  defp slider(nil, fallback), do: fallback

  defp slider(value, fallback) when is_binary(value) do
    case Float.parse(value) do
      {f, _rest} -> f
      :error -> fallback
    end
  end

  # lê os pickers de cor (hex dos <input type=color>) sobre o estado atual
  defp merge_form_colors(form, current) do
    Enum.reduce(Layers.groups(), current, fn %{key: key}, acc ->
      case form["layer_#{key}"] do
        "#" <> _ = hex -> Map.put(acc, key, hex_to_rgb(hex))
        _ -> acc
      end
    end)
  end

  defp hex_to_rgb("#" <> <<r::binary-2, g::binary-2, b::binary-2>>) do
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  # %{skin: {r,g,b}, ...} -> %{"skin" => [r,g,b], ...} (JSON-safe pro manifest)
  defp serialize_colors(colors) do
    Map.new(colors, fn {k, {r, g, b}} -> {to_string(k), [r, g, b]} end)
  end
end
