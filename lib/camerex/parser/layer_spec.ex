defmodule Camerex.Parser.LayerSpec do
  @moduledoc """
  Metadados declarativos de uma camada. FONTE ÚNICA do que hoje vive em 6
  lugares (`@param_keys` da `Library`; `@sliders` / `@booleans` / `defstruct` /
  `@type` do `RenderParams`; `render_opts`/`frame_opts`/`maybe_*` dos
  pipelines). Inspecionável em runtime, consumido pelo `LayerRegistry`, pelo
  reduce do `LayerRunner` e pela UI (via `LayerRegistry.ui_specs/0` que tira
  `:module` antes de mandar pro front).

  Campos:
    * `id`           — atom (`:object`, `:hair`, `:apparatus`, `:skin`).
    * `module`       — módulo que implementa `@behaviour Camerex.Parser.Layer`.
    * `label`        — string mostrada na UI.
    * `class`        — classe virtual injetada nos labels (18/2/19/11).
    * `group`        — `%{key, label, ids, default}` se cria entrada nova em
                       `Layers`; `nil` se reusa grupo ATR existente (Hair/Skin).
    * `fg_spec`      — `%{model, kind}` (`"u2net"`|`"u2netp"` × `:largest`|
                       `:full`) ou `:none` (Skin não consome U²-Net).
    * `color_mode`   — `:required` (Hair) | `:optional` (Apparatus) | `:auto`
                       (Skin) | `:none` (Object).
    * `gate`         — `:always` (Object/Apparatus/Skin) | `:run_when_atr_blind`
                       (Hair: roda só se `Hair.present?(labels)==false`).
    * `params`       — `[%{key, kind, default, ui_hint}]` (`kind` ∈
                       `:bool|:slider|:color|:model`).
    * `sampleable?`  — true sse o módulo implementa `Layer.Sampleable`.
    * `order_band`   — `:baseline | :overlay | :destructive` (ordena o reduce;
                       Skin destrutivo por último).
  """

  @type fg_spec :: %{model: String.t(), kind: :largest | :full} | :none

  @type param :: %{
          required(:key) => atom(),
          required(:kind) => :bool | :slider | :color | :model,
          required(:default) => any(),
          optional(:ui_hint) => String.t()
        }

  @type t :: %__MODULE__{
          id: atom(),
          module: module(),
          label: String.t(),
          class: pos_integer(),
          group: map() | nil,
          fg_spec: fg_spec(),
          color_mode: :required | :optional | :auto | :none,
          gate: :always | :run_when_atr_blind,
          params: [param()],
          sampleable?: boolean(),
          order_band: :baseline | :overlay | :destructive
        }

  defstruct [
    :id,
    :module,
    :label,
    :class,
    :group,
    :fg_spec,
    :color_mode,
    :gate,
    :params,
    :sampleable?,
    :order_band
  ]
end
