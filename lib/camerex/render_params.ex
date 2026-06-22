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

  alias Camerex.Parser.Layers

  # sliders viram float (parse com fallback); booleanos vêm de `== "true"`
  @sliders ~w(halo bloom trail detail bg_opacity fill_color fill_texture glow spread aerial_sensitivity)a
  @booleans ~w(detect_object detect_aerial transparent_bg fill floor)a

  @type rgb :: {0..255, 0..255, 0..255}
  @type t :: %__MODULE__{
          layer_colors: %{atom() => rgb()},
          halo: float(),
          bloom: float(),
          trail: float(),
          detail: float(),
          bg_opacity: float(),
          fill_color: float(),
          fill_texture: float(),
          glow: float(),
          spread: float(),
          aerial_sensitivity: float(),
          detect_object: boolean(),
          detect_aerial: boolean(),
          aerial_color: rgb(),
          transparent_bg: boolean(),
          fill: boolean(),
          floor: boolean()
        }

  defstruct layer_colors: %{},
            halo: 0.6,
            bloom: 0.4,
            trail: 0.7,
            detail: 0.5,
            bg_opacity: 0.0,
            fill_color: 0.45,
            fill_texture: 0.15,
            glow: 0.85,
            spread: 0.5,
            aerial_sensitivity: 0.5,
            detect_object: false,
            detect_aerial: false,
            # cor REAL do tecido na foto (pista de detecção do modo aéreo);
            # default vermelho, que é o silk mais comum
            aerial_color: {220, 30, 40},
            transparent_bg: false,
            fill: false,
            floor: false

  @spec default() :: t()
  def default, do: %__MODULE__{layer_colors: Layers.default_colors()}

  @doc "Strings do `<form>` (phx-change \"validate\") → struct; mantém `current` onde faltar."
  @spec from_form(map(), t()) :: t()
  def from_form(form, %__MODULE__{} = current) do
    @sliders
    |> Map.new(fn k -> {k, slider(form[to_string(k)], Map.fetch!(current, k))} end)
    |> Map.merge(Map.new(@booleans, fn k -> {k, form[to_string(k)] == "true"} end))
    |> Map.put(:layer_colors, merge_form_colors(form, current.layer_colors))
    |> Map.put(:aerial_color, form_rgb(form["aerial_color"], current.aerial_color))
    |> then(&struct(current, &1))
  end

  @doc "Params salvos no item (reprocesso) → struct; `current` é fallback dos sliders."
  @spec from_manifest(map(), t()) :: t()
  def from_manifest(%{"params" => p}, %__MODULE__{} = current) when is_map(p) do
    @sliders
    |> Map.new(fn k -> {k, p[to_string(k)] || Map.fetch!(current, k)} end)
    |> Map.merge(Map.new(@booleans, fn k -> {k, p[to_string(k)] || false} end))
    |> Map.put(:layer_colors, Layers.normalize_colors(p["layer_colors"]))
    |> Map.put(:aerial_color, list_rgb(p["aerial_color"], current.aerial_color))
    |> then(&struct(current, &1))
  end

  def from_manifest(_item, %__MODULE__{} = current), do: current

  @doc "Struct → mapa string-keyed do manifest (sem `model`, que o chamador acrescenta)."
  @spec to_manifest(t()) :: %{String.t() => term()}
  def to_manifest(%__MODULE__{} = p) do
    (@sliders ++ @booleans)
    |> Map.new(fn k -> {to_string(k), Map.fetch!(p, k)} end)
    |> Map.put("layer_colors", serialize_colors(p.layer_colors))
    |> Map.put("aerial_color", Tuple.to_list(p.aerial_color))
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
