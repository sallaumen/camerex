defmodule Camerex.Parser.Layer do
  @moduledoc """
  Contrato comum das camadas-detector. Cada implementação consome um
  `Camerex.Parser.LayerContext` e devolve uma máscara u8 `{h, w}` (0|255);
  `into_labels/2` injeta a classe virtual da camada nos labels do parser ATR.

  Os 3 orquestradores (photo/video/calibration) consomem as camadas via
  `Camerex.Pipeline.LayerRunner.run/4`, que aplica o reduce sobre a lista do
  `Camerex.Parser.LayerRegistry`.
  """

  alias Camerex.Parser.LayerContext

  @callback run(LayerContext.t()) :: Nx.Tensor.t()
  @callback into_labels(labels :: Nx.Tensor.t(), mask :: Nx.Tensor.t()) :: Nx.Tensor.t()
end

defmodule Camerex.Parser.Layer.Sampleable do
  @moduledoc """
  Behaviour opcional para camadas que ganham amostragem de cor/modelo por REGIÃO
  arrastada na prévia. Hoje só `Hair` implementa. Sample por região (bbox), não
  por ponto — clique→modelo foi refutado no pixel real (foto-3: vazou cabeça→
  tronco; ancorado colapsou pra 0).
  """

  @callback sample_region(
              rgb :: Nx.Tensor.t(),
              bbox :: {number(), number(), number(), number()}
            ) :: map() | nil
end
