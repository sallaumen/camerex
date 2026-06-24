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
      params: [
        %{
          key: :detect_head_fusion,
          kind: :bool,
          default: false,
          label: "Recuperar cabeça (pose aérea)",
          ui_hint:
            "Quando o cabelo/rosto somem em pose invertida, funde um segundo modelo (SCHP) em várias rotações para recuperá-los. Mais lento e só para foto."
        }
      ],
      sampleable?: false,
      order_band: :baseline,
      tags: ["Acrobacia"]
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
      params: [
        %{
          key: :detect_person_fill,
          kind: :bool,
          default: false,
          label: "Preencher silhueta (pose aérea)",
          ui_hint:
            "Em pose aérea/invertida o detector às vezes joga partes da pessoa no fundo e ela some; isto fecha esses buracos com uma silhueta robusta (BiRefNet). Pesado em vídeo (~5s/frame)."
        }
      ],
      sampleable?: false,
      order_band: :baseline,
      tags: ["Acrobacia"]
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
      params: [
        %{
          key: :detect_object,
          kind: :bool,
          default: false,
          label: "Objeto na mão",
          ui_hint:
            "Destaca o que a pessoa segura — instrumento, microfone — com um segundo modelo (U²-Net)."
        }
      ],
      sampleable?: false,
      order_band: :baseline,
      tags: ["Música"]
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
        %{
          key: :detect_aerial,
          kind: :bool,
          default: false,
          label: "Acrobacia aérea (tecido)",
          ui_hint:
            "Destaca o tecido vertical (silk) que a pessoa escala, como uma camada própria."
        },
        %{
          key: :aerial_color,
          kind: :color,
          default: {220, 30, 40},
          label: "Cor do tecido na foto",
          ui_hint: "A cor real do tecido na foto original, para o detector localizá-lo."
        },
        %{
          key: :aerial_sensitivity,
          kind: :slider,
          default: 0.5,
          label: "Sensibilidade do tecido",
          ui_hint:
            "Mais alto pega mais tecido (e mais risco de mancha); mais baixo fica limpo. Tecido vívido sobre fundo da mesma cor pede valor baixo; tecido sutil sobre fundo limpo pede alto."
        }
      ],
      sampleable?: false,
      order_band: :baseline,
      tags: ["Acrobacia"]
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
        %{
          key: :detect_hair,
          kind: :bool,
          default: false,
          label: "Resgatar cabelo",
          ui_hint:
            "Quando o detector não acha a cabeça (pose aérea ou de costas), localiza o cabelo pela cor que você indicar."
        },
        %{
          key: :hair_color,
          kind: :color,
          default: {60, 45, 40},
          label: "Cor do cabelo na foto",
          ui_hint: "A cor real do cabelo na foto original, para o detector localizá-lo."
        },
        %{key: :hair_model, kind: :model, default: nil},
        %{
          key: :hair_sensitivity,
          kind: :slider,
          default: 0.5,
          label: "Sensibilidade do cabelo",
          ui_hint:
            "Mais alto resgata mais cabelo (e mais risco de pegar fundo parecido); mais baixo fica conservador. Use quando a cabeça some em pose aérea ou de costas."
        }
      ],
      sampleable?: true,
      order_band: :overlay,
      tags: ["Acrobacia"]
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
        %{
          key: :detect_skin,
          kind: :bool,
          default: false,
          label: "Pele do torso nu",
          ui_hint:
            "Quando a pessoa está sem a parte de cima, re-rotula costas e tronco (que o detector pinta como roupa) de volta como pele, aprendendo a cor dos braços e pernas."
        },
        %{
          key: :skin_sensitivity,
          kind: :slider,
          default: 0.5,
          label: "Sensibilidade da pele",
          ui_hint:
            "Mais alto re-rotula mais roupa como pele (risco de pegar a calça); mais baixo fica conservador. Só afeta poses sem top (costas/tronco à mostra)."
        }
      ],
      sampleable?: false,
      order_band: :destructive,
      tags: ["Acrobacia"]
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

  @doc """
  Tags de uso presentes, na ordem de 1ª aparição (que segue a ordem das camadas).
  Sem repetição; tags vazias não entram. A UI agrupa as camadas por estas.
  """
  @spec tags() :: [String.t()]
  def tags, do: all() |> Enum.flat_map(& &1.tags) |> Enum.uniq()

  @doc "Projeção sem `:module` — segura pra ir pros assigns da UI sem vazar captures."
  @spec ui_specs() :: [map()]
  def ui_specs, do: Enum.map(all(), &(&1 |> Map.from_struct() |> Map.delete(:module)))
end
