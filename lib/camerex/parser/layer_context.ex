defmodule Camerex.Parser.LayerContext do
  @moduledoc """
  Contexto normalizado passado a cada `Camerex.Parser.Layer.run/1`. Acumulador do
  reduce do `Camerex.Pipeline.LayerRunner`: `labels` é atualizado a cada
  `into_labels`; `fg` é pré-resolvido por camada segundo seu `fg_spec`.
  """

  @type rgb :: {0..255, 0..255, 0..255}
  @type color :: rgb() | map() | nil

  @type t :: %__MODULE__{
          rgb: Nx.Tensor.t(),
          labels: Nx.Tensor.t(),
          fg: Nx.Tensor.t() | nil,
          color: color(),
          sensitivity: float(),
          video?: boolean(),
          spatial?: boolean()
        }

  defstruct [:rgb, :labels, fg: nil, color: nil, sensitivity: 0.5, video?: false, spatial?: true]
end
