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

  # dilata a pessoa antes de subtrair: come a borda de descasamento entre os dois
  # modelos (senão sobra um anel de "objeto" em volta da pessoa inteira).
  @person_dilate_div 40
  # fecha buracos do objeto (cordas/vãos do instrumento) num corpo só.
  @close_div 50
  # só componentes grandes viram objeto — corta chuvisco e restos da borda.
  @min_area_frac 0.01
  @object_class 18

  @doc """
  Máscara u8 `{h, w}` (0|255) do objeto, dados o foreground do U²-Net (u8) e os
  rótulos ATR (`{h, w}` u8). Vazio quando o foreground ≈ a pessoa (sem objeto).
  """
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
    |> drop_small_components(round(h * w * @min_area_frac))
  end

  @doc """
  Injeta a classe `18` nos rótulos onde HÁ objeto E o ATR não rotulou nada (não
  sobrescreve pessoa). Devolve os labels aumentados.
  """
  @spec into_labels(Nx.Tensor.t(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def into_labels(labels, object_u8) do
    where = Nx.logical_and(Nx.greater(object_u8, 0), Nx.equal(labels, 0))
    Nx.select(where, Nx.broadcast(Nx.u8(@object_class), Nx.shape(labels)), labels)
  end

  # mantém só componentes conectados ≥ min_area (o objeto), descarta o resto
  defp drop_small_components(mask_u8, min_area) do
    {_n, lbls, stats, _c} = Evision.connectedComponentsWithStats(Evision.Mat.from_nx(mask_u8))
    areas = Evision.Mat.to_nx(stats, Nx.BinaryBackend)[[.., 4]]

    keep =
      areas
      |> Nx.greater_equal(min_area)
      |> Nx.as_type(:u8)
      |> Nx.put_slice([0], Nx.tensor([0], type: :u8))

    lbls_nx = lbls |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.as_type(:s64)
    keep |> Nx.take(lbls_nx) |> Nx.multiply(255) |> Nx.as_type(:u8)
  end

  defp kernel(s) do
    k = max(s, 1)
    Evision.getStructuringElement(Evision.Constant.cv_MORPH_ELLIPSE(), {k, k})
  end
end
