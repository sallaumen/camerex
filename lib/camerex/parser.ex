defmodule Camerex.Parser do
  @moduledoc """
  Port de human parsing: rotula cada pixel por **parte** (classes ATR 0..17 —
  cabelo, rosto, roupa, calça, etc.). Input `{h, w, 3}` u8 RGB; output
  `{h, w}` u8 com o id da classe por pixel. A implementação ativa vem de
  `config :camerex, :parser` (Segformer ONNX em dev/prod, Fixture em teste).

  Diferente do `Camerex.Segmenter` (uma máscara de "pessoa"), o parser separa
  as partes — é o que permite colorir roupa e pele com cores distintas.
  """

  @callback parse(Nx.Tensor.t(), keyword()) :: {:ok, Nx.Tensor.t()} | {:error, term()}

  @spec parse(Nx.Tensor.t(), keyword()) :: {:ok, Nx.Tensor.t()} | {:error, term()}
  def parse(rgb, opts \\ []) do
    impl = Application.fetch_env!(:camerex, :parser)
    impl.parse(rgb, opts)
  end
end
