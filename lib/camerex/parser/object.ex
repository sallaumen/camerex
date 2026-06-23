defmodule Camerex.Parser.Object do
  @moduledoc """
  Detecção do OBJETO na mão (instrumento, microfone, etc.) por DIFERENÇA de
  modelos: o foreground saliente do U²-Net MENOS as partes-de-pessoa do ATR é o
  que a pessoa segura. Vira a classe virtual 18 (grupo `:object` em `Layers`),
  colorível como qualquer camada.

  Não é semântico ("não sabe que é um baixo") — é "o resto do foreground que não
  é a pessoa". Mas captura instrumentos e objetos segurados que o ATR ignora
  (vinham como buraco preto). Opt-in: roda o U²-Net além do parser.

  Puro (recebe foreground e labels; quem roda o U²-Net é o chamador).
  """

  @behaviour Camerex.Parser.Layer
  alias Camerex.Parser.LayerContext

  # dilata a pessoa antes de subtrair: come a borda de descasamento entre os dois
  # modelos (senão sobra um anel de "objeto" em volta da pessoa inteira).
  @person_dilate_div 40
  # fecha buracos do objeto (cordas/vãos do instrumento) num corpo só.
  @close_div 50
  # um componente vira objeto se for GRANDE (≥ @min_area_frac)…
  @min_area_frac 0.01
  # …OU menor, mas TOCANDO a borda do quadro (≥ @edge_min_area_frac): é o
  # instrumento/objeto CORTADO pela moldura. Tocar a borda é o que separa "objeto
  # incompleto" (real, cortado) de chuvisco solto no meio — então admite o
  # parcial sem reabrir a porta pro ruído interno.
  @edge_min_area_frac 0.002
  @object_class 18

  @doc """
  Máscara u8 `{h, w}` (0|255) do objeto, dados o foreground do U²-Net (u8) e os
  rótulos ATR (`{h, w}` u8). Vazio quando o foreground ≈ a pessoa (sem objeto).
  """
  @impl Camerex.Parser.Layer
  @spec run(LayerContext.t()) :: Nx.Tensor.t()
  def run(%LayerContext{fg: fg, labels: labels}), do: detect(fg, labels)

  @spec detect(Nx.Tensor.t(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def detect(fg_u8, labels) do
    {h, w} = Nx.shape(labels)

    person_dilated =
      labels
      |> Nx.greater(0)
      |> Nx.multiply(255)
      |> Nx.as_type(:u8)
      |> Evision.Mat.from_nx()
      |> Evision.dilate(kernel(round(w / @person_dilate_div)))
      |> Evision.Mat.to_nx(Nx.BinaryBackend)
      |> Nx.greater(0)

    fg_u8
    |> Nx.greater(0)
    |> Nx.logical_and(Nx.logical_not(person_dilated))
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
    |> Evision.Mat.from_nx()
    |> Evision.morphologyEx(Evision.Constant.cv_MORPH_CLOSE(), kernel(round(w / @close_div)))
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> keep_object_components(h, w)
  end

  @doc """
  Injeta a classe `18` nos rótulos onde HÁ objeto E o ATR não rotulou nada (não
  sobrescreve pessoa). Devolve os labels aumentados.
  """
  @impl Camerex.Parser.Layer
  @spec into_labels(Nx.Tensor.t(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def into_labels(labels, object_u8) do
    where = Nx.logical_and(Nx.greater(object_u8, 0), Nx.equal(labels, 0))
    Nx.select(where, Nx.broadcast(Nx.u8(@object_class), Nx.shape(labels)), labels)
  end

  # mantém os componentes do objeto: GRANDES, ou menores que TOCAM a borda do
  # quadro (objeto cortado pela moldura — instrumento incompleto). stats do
  # connectedComponents: colunas [x, y, largura, altura, área].
  defp keep_object_components(mask_u8, h, w) do
    {_n, lbls, stats, _c} = Evision.connectedComponentsWithStats(Evision.Mat.from_nx(mask_u8))
    s = Evision.Mat.to_nx(stats, Nx.BinaryBackend)
    {x, y, bw, bh, area} = {s[[.., 0]], s[[.., 1]], s[[.., 2]], s[[.., 3]], s[[.., 4]]}

    touches_edge =
      Nx.equal(x, 0)
      |> Nx.logical_or(Nx.equal(y, 0))
      |> Nx.logical_or(Nx.greater_equal(Nx.add(x, bw), w))
      |> Nx.logical_or(Nx.greater_equal(Nx.add(y, bh), h))

    big = Nx.greater_equal(area, round(h * w * @min_area_frac))

    cut_off =
      Nx.logical_and(Nx.greater_equal(area, round(h * w * @edge_min_area_frac)), touches_edge)

    keep =
      big
      |> Nx.logical_or(cut_off)
      |> Nx.as_type(:u8)
      # rótulo 0 = fundo (toca todas as bordas e é enorme): nunca acende
      |> Nx.put_slice([0], Nx.tensor([0], type: :u8))

    lbls_nx = lbls |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.as_type(:s64)
    keep |> Nx.take(lbls_nx) |> Nx.multiply(255) |> Nx.as_type(:u8)
  end

  defp kernel(s) do
    k = max(s, 1)
    Evision.getStructuringElement(Evision.Constant.cv_MORPH_ELLIPSE(), {k, k})
  end
end
