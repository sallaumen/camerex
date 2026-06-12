defmodule Camerex.Segmenter do
  @moduledoc """
  Port de segmentação de pessoas. Input `{h, w, 3}` u8 RGB; output máscara
  `{h, w}` u8 com valores 0 | 255 (limiar alpha > 30 nos adapters reais).
  A implementação ativa vem de `config :camerex, :segmenter`
  (Ortex em dev/prod, Fixture em teste).

  opts: `model: "u2net" | "u2netp"` (default `"u2net"`).
  """

  @callback segment(Nx.Tensor.t(), keyword()) :: {:ok, Nx.Tensor.t()} | {:error, term()}
end
