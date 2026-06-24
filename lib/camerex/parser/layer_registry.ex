defmodule Camerex.Parser.LayerRegistry do
  @moduledoc """
  Catálogo ORDENADO das camadas-detector. Compile-time (lista literal, sem
  `String.to_atom` de input do usuário). Ordem por `order_band`:
  baseline → overlay → destructive. O `Skin` re-rotula roupa→pele (one-way) e
  precisa rodar por ÚLTIMO sobre labels já aumentados por Hair/etc.

  Adicionar camada = novo módulo (com `@behaviour Camerex.Parser.Layer`) + uma
  entrada aqui. Tudo o mais (params do `RenderParams`, pipelines, UI) deriva
  daqui — sem listas paralelas mantidas à mão.
  """

  alias Camerex.Parser.{Apparatus, Hair, HeadFusion, LayerSpec, Object, PersonFill, Skin}

  @layers [
    %LayerSpec{
      id: :head_fusion,
      module: HeadFusion,
      label: "Recuperar cabeça (multi-parser, pose aérea)",
      class: 2,
      group: nil,
      fg_spec: %{model: "u2netp", kind: :full},
      color_mode: :none,
      gate: :always,
      params: [%{key: :detect_head_fusion, kind: :bool, default: false}],
      sampleable?: false,
      order_band: :baseline
    },
    %LayerSpec{
      id: :person_fill,
      module: PersonFill,
      label: "Preencher buracos (pose aérea)",
      class: 11,
      group: nil,
      fg_spec: %{model: "birefnet-lite", kind: :full},
      color_mode: :none,
      gate: :always,
      params: [%{key: :detect_person_fill, kind: :bool, default: false}],
      sampleable?: false,
      order_band: :baseline
    },
    %LayerSpec{
      id: :object,
      module: Object,
      label: "Objeto na mão",
      class: 18,
      group: %{key: :object, label: "objeto/instrumento", ids: [18], default: {90, 200, 255}},
      fg_spec: %{model: "u2net", kind: :largest},
      color_mode: :none,
      gate: :always,
      params: [%{key: :detect_object, kind: :bool, default: false}],
      sampleable?: false,
      order_band: :baseline
    },
    %LayerSpec{
      id: :apparatus,
      module: Apparatus,
      label: "Tecido aéreo",
      class: 19,
      group: %{key: :apparatus, label: "tecido aéreo", ids: [19], default: {255, 40, 120}},
      fg_spec: %{model: "u2netp", kind: :full},
      color_mode: :optional,
      gate: :always,
      params: [
        %{key: :detect_aerial, kind: :bool, default: false},
        %{key: :aerial_color, kind: :color, default: {220, 30, 40}},
        %{key: :aerial_sensitivity, kind: :slider, default: 0.5}
      ],
      sampleable?: false,
      order_band: :baseline
    },
    %LayerSpec{
      id: :hair,
      module: Hair,
      label: "Resgatar cabelo (pose aérea)",
      class: 2,
      group: nil,
      fg_spec: %{model: "u2net", kind: :largest},
      color_mode: :required,
      gate: :run_when_atr_blind,
      params: [
        %{key: :detect_hair, kind: :bool, default: false},
        %{key: :hair_color, kind: :color, default: {60, 45, 40}},
        %{key: :hair_model, kind: :model, default: nil},
        %{key: :hair_sensitivity, kind: :slider, default: 0.5}
      ],
      sampleable?: true,
      order_band: :overlay
    },
    %LayerSpec{
      id: :skin,
      module: Skin,
      label: "Pele do torço nu",
      class: 11,
      group: nil,
      fg_spec: :none,
      color_mode: :auto,
      gate: :always,
      params: [
        %{key: :detect_skin, kind: :bool, default: false},
        %{key: :skin_sensitivity, kind: :slider, default: 0.5}
      ],
      sampleable?: false,
      order_band: :destructive
    }
  ]

  @band_rank %{baseline: 0, overlay: 1, destructive: 2}

  @spec all() :: [LayerSpec.t()]
  def all, do: Enum.sort_by(@layers, &Map.fetch!(@band_rank, &1.order_band))

  @spec fetch(atom() | String.t()) :: LayerSpec.t() | nil
  def fetch(id) when is_atom(id), do: Enum.find(all(), &(&1.id == id))
  def fetch(id) when is_binary(id), do: Enum.find(all(), &(to_string(&1.id) == id))

  @doc """
  Camadas ativas: o param `:bool` da camada (derivado do spec, não do `id`) é
  `true` no mapa string-keyed (caminho do manifest/form). Ex.: `apparatus` ativa
  via `detect_aerial`, não `detect_apparatus`.
  """
  @spec active(map()) :: [LayerSpec.t()]
  def active(params) when is_map(params) do
    Enum.filter(all(), fn spec ->
      case LayerSpec.param_key(spec, :bool) do
        nil -> false
        key -> Map.get(params, to_string(key)) == true
      end
    end)
  end

  @doc ~S"""
  Conjunto `{model, kind}` que `LayerRunner`/`Calibration` precisa segmentar pra
  alimentar as camadas dadas. Camadas com `fg_spec: :none` são ignoradas.
  """
  @spec required_segmentations([LayerSpec.t()]) :: MapSet.t({String.t(), :largest | :full})
  def required_segmentations(specs) do
    specs
    |> Enum.flat_map(fn
      %{fg_spec: :none} -> []
      %{fg_spec: %{model: m, kind: k}} -> [{m, k}]
    end)
    |> MapSet.new()
  end

  @doc "Chaves planas dos params de TODAS as camadas (deriva o `Library.param_keys/0`)."
  @spec param_keys() :: [String.t()]
  def param_keys do
    all() |> Enum.flat_map(& &1.params) |> Enum.map(&to_string(&1.key))
  end

  @doc "Projeção sem `:module` — segura pra ir pros assigns da UI sem vazar captures."
  @spec ui_specs() :: [map()]
  def ui_specs, do: Enum.map(all(), &(&1 |> Map.from_struct() |> Map.delete(:module)))
end
