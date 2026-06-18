defmodule Camerex.Parser.Apparatus do
  @moduledoc """
  Detecção do APARELHO AÉREO (tecido/silk) por geometria, sem IA generativa.

  O tecido é uma estrutura **alta e vertical** que pende do equipamento e cruza
  boa parte da altura do quadro. No `U²-Net foreground − pessoa` ele sobra como
  um componente comprido; o ruído de descasamento dos dois modelos fica em
  pedaços pequenos e largos colados na pessoa. Então: ficamos com os componentes
  **altos E verticais** (altura ≥ fração do quadro e altura ≥ largura).

  Vira a classe virtual 19 (grupo `:apparatus` em `Layers`), colorível.

  IMPORTANTE: recebe o foreground **COMPLETO** do U²-Net (todos os componentes,
  `raw > 0`), NÃO o `Mask.largest_component` — o tecido e a pessoa costumam ser
  componentes separados, e o maior pode ser qualquer um dos dois. Puro (quem roda
  o U²-Net é o chamador).

  Limitação conhecida: se a cena é banhada por luz monocromática (ex.: vermelho
  forte sobre tecido vermelho), o U²-Net não vê o tecido como saliente e ele nem
  entra no foreground — aí nenhum método local o recupera.
  """

  # dilata a pessoa antes de subtrair (come o anel de descasamento dos modelos)
  @person_dilate_div 45
  # fecha vãos do drapeado num corpo contínuo
  @close_div 40
  # span vertical mínimo: o tecido cruza ≥ 35% da altura do quadro
  @min_height_frac 0.35
  # área mínima — corta restos pequenos
  @min_area_frac 0.005
  @apparatus_class 19

  @doc """
  Máscara u8 `{h, w}` (0|255) do tecido, dado o foreground COMPLETO do U²-Net
  (u8, todos os componentes) e os rótulos ATR. Vazio quando não há estrutura
  alta/vertical não-pessoa (sem aparelho, ou tecido não-saliente).
  """
  @spec detect(Nx.Tensor.t(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def detect(full_fg_u8, labels) do
    {h, w} = Nx.shape(labels)

    person =
      labels
      |> Nx.greater(0)
      |> Nx.multiply(255)
      |> Nx.as_type(:u8)
      |> Evision.Mat.from_nx()
      |> Evision.dilate(kernel(round(w / @person_dilate_div)))
      |> Evision.Mat.to_nx(Nx.BinaryBackend)
      |> Nx.greater(0)

    full_fg_u8
    |> Nx.greater(0)
    |> Nx.logical_and(Nx.logical_not(person))
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
    |> Evision.Mat.from_nx()
    |> Evision.morphologyEx(Evision.Constant.cv_MORPH_CLOSE(), kernel(round(w / @close_div)))
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> keep_tall_vertical(h, w)
  end

  @doc """
  Injeta a classe `19` nos rótulos onde HÁ tecido E o ATR não rotulou nada (não
  sobrescreve pessoa). Devolve os labels aumentados.
  """
  @spec into_labels(Nx.Tensor.t(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def into_labels(labels, apparatus_u8) do
    where = Nx.logical_and(Nx.greater(apparatus_u8, 0), Nx.equal(labels, 0))
    Nx.select(where, Nx.broadcast(Nx.u8(@apparatus_class), Nx.shape(labels)), labels)
  end

  # mantém componentes ALTOS (bbox h ≥ @min_height_frac) E VERTICAIS (h ≥ largura)
  # e acima da área mínima. stats: colunas [x, y, largura, altura, área].
  defp keep_tall_vertical(mask_u8, h, w) do
    {_n, lbls, stats, _c} = Evision.connectedComponentsWithStats(Evision.Mat.from_nx(mask_u8))
    s = Evision.Mat.to_nx(stats, Nx.BinaryBackend)
    {bw, bh, area} = {s[[.., 2]], s[[.., 3]], s[[.., 4]]}

    tall = Nx.greater_equal(bh, round(h * @min_height_frac))
    vertical = Nx.greater_equal(bh, bw)
    big = Nx.greater_equal(area, round(h * w * @min_area_frac))

    keep =
      tall
      |> Nx.logical_and(vertical)
      |> Nx.logical_and(big)
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
