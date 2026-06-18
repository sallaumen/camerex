defmodule Camerex.Parser.Apparatus do
  @moduledoc """
  Detecção do APARELHO AÉREO (tecido/silk) por geometria + cor, sem IA generativa.

  O tecido é uma estrutura **alta e vertical** que pende do equipamento. Duas
  pistas se somam:

    * **U²-Net foreground COMPLETO − pessoa** — o tecido saliente que sobra (mas
      o U²-Net às vezes perde o drapeado, ou não vê o tecido sob luz colorida).
    * **cor do tecido** (opt-in, o usuário indica a cor real do tecido na foto) —
      pixels com aquele MATIZ e bem saturados. Recupera o drapeado inteiro e
      funciona mesmo quando o U²-Net falha, porque o tecido é mais saturado que
      paredes claras (e que paredes sob luz colorida).

  A união das pistas, menos a pessoa, é filtrada por geometria: ficam só os
  componentes ALTOS (≥35% da altura) e VERTICAIS (altura ≥ largura) — assim
  parede (bloco largo) e ruído (pequeno) caem, e o tecido (faixa vertical) fica.

  Vira a classe virtual 19 (grupo `:apparatus` em `Layers`), colorível.

  IMPORTANTE: recebe o foreground **COMPLETO** do U²-Net (todos os componentes,
  `raw > 0`), NÃO o `Mask.largest_component` — tecido e pessoa são componentes
  separados. Puro (quem roda o U²-Net é o chamador).

  Limitação: cena banhada em luz monocromática (tudo da mesma cor saturada do
  tecido) — nem cor nem saliência separam o tecido do fundo.
  """

  alias Camerex.Neon.Palette

  # dilata a pessoa antes de subtrair (come o anel de descasamento dos modelos)
  @person_dilate_div 35
  # fecha vãos do drapeado — gentil, pra não fundir o tecido com blocos largos
  @close_div 120
  # span vertical mínimo: o tecido cruza ≥ 30% da altura do quadro
  @min_height_frac 0.30
  # área mínima — corta restos pequenos
  @min_area_frac 0.003
  # pista de cor: matiz dentro de ±tol do tecido (0..179 circular) e saturado
  @hue_tol 12
  @sat_min 120
  @apparatus_class 19

  @doc """
  Máscara u8 `{h, w}` (0|255) do tecido.

    * `full_fg_u8` — foreground COMPLETO do U²-Net (todos os componentes).
    * `labels` — rótulos ATR (pra subtrair a pessoa).
    * `rgb` — a imagem (pra pista de cor); `nil` desliga a cor.
    * `color` — `{r,g,b}` da cor real do tecido na foto; `nil` desliga a cor.
  """
  @spec detect(Nx.Tensor.t(), Nx.Tensor.t(), Nx.Tensor.t() | nil, Palette.color() | nil) ::
          Nx.Tensor.t()
  def detect(full_fg_u8, labels, rgb \\ nil, color \\ nil) do
    {h, w} = Nx.shape(labels)
    color = normalize_color(color)

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
    |> with_color_cue(rgb, color)
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

  # cor vem como {r,g,b} (struct) ou [r,g,b] (manifest/JSON); nil = sem pista
  defp normalize_color([r, g, b]), do: {r, g, b}
  defp normalize_color({_, _, _} = c), do: c
  defp normalize_color(_), do: nil

  # sem cor/imagem → só a pista do U²-Net (base) vale
  defp with_color_cue(base, rgb, color) when is_nil(rgb) or is_nil(color), do: base

  # com cor indicada: usa SÓ a pista de cor (pixels com o MATIZ do tecido ±tol,
  # circular em 0..179, e bem saturados). Não une com o U²-Net: unir funde o
  # tecido com áreas coloridas do corpo em blocos largos que o filtro vertical
  # rejeita — a cor sozinha pega o drapeado inteiro e é o que o usuário controla.
  defp with_color_cue(_base, rgb, {_, _, _} = color) do
    target = hue_of(color)
    [hue_c, sat_c, _v] = rgb |> to_hsv() |> Evision.split()
    hue = hue_c |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.as_type(:s32)
    sat = sat_c |> Evision.Mat.to_nx(Nx.BinaryBackend)

    dist = Nx.abs(Nx.subtract(hue, target))
    circular = Nx.min(dist, Nx.subtract(180, dist))
    Nx.logical_and(Nx.less_equal(circular, @hue_tol), Nx.greater(sat, @sat_min))
  end

  defp hue_of({r, g, b}) do
    [[[h, _s, _v]]] =
      Nx.tensor([[[r, g, b]]], type: :u8)
      |> to_hsv()
      |> Evision.Mat.to_nx(Nx.BinaryBackend)
      |> Nx.to_list()

    h
  end

  defp to_hsv(%Nx.Tensor{} = t),
    do: t |> Evision.Mat.from_nx_2d() |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2HSV())

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
