defmodule Camerex.Parser.Apparatus do
  @moduledoc """
  Detecção do APARELHO AÉREO (tecido/silk) por saliência + cor + geometria, sem
  IA generativa. O tecido pende SEMPRE do topo (invariante: 2 linhas ou 1 grossa
  que bifurca; "só embaixo" não existe), é LISO/FINO e desce — às vezes até o
  chão, às vezes só pra cima. Pipeline (validado nas fotos reais do Lucas):

    1. **Evidência** = `(saliência ∩ saturado) ∪ cor-vibrante`, menos a pessoa.
       A saliência (U²-Net, idealmente `u2netp`) acha a estrutura; a porta de
       saturação tira pele/parede iluminada (que tem sat baixa) sem depender do
       MATIZ (a luz quente deixa tudo avermelhado); a **cor-vibrante** (matiz do
       tecido ±tol e MUITO saturado) ENRIQUECE — recupera o fio fino do topo que
       a saliência perde, sem trazer o fundo.
    2. **Guarda anti-monocromático:** se a cor-vibrante pega >40% do quadro, a
       cena é monocromática (tudo da cor do tecido) → a cor não discrimina,
       desliga e confia só na saliência.
    3. **Ponte vertical** (close por linha 1×alta) reconecta o tecido partido
       pela pessoa — liga o fio do topo ao drapeado de baixo numa fita só.
    4. **Reconstrução com semente VERTICAL crescendo na parte FINA:** semeia nas
       fitas verticais finas e cresce ao longo delas, parando em qualquer blob
       gordo (parede falsa, objeto colorido, membro) — distingue
       "largo-mas-é-tecido" (drapeado conectado à fita) de "largo-e-é-mancha".
    5. **Âncora de topo:** só fica componente que ALCANÇA o topo do quadro (o
       invariante). Derruba drapeado solto e blob no meio.

  Vira a classe virtual 19 (grupo `:apparatus` em `Layers`), colorível.

  Recebe o foreground **COMPLETO** do U²-Net (todos os componentes, `raw > 0`),
  NÃO o `Mask.largest_component` — tecido e pessoa são componentes separados.
  Puro (quem roda o U²-Net é o chamador).
  """

  alias Camerex.Parser.Layers

  # pessoa subtraída: todos os rótulos ATR dilatados, + blindagem extra do CABELO
  # (classe 2): tingido ele cai no matiz de um silk quente e o ATR sub-segmenta a
  # borda — sem isso o cabelo rosa virava tecido (regressão coberta em teste).
  @person_dilate_div 35
  @hair_class 2
  @hair_dilate_div 8

  # cor-vibrante: matiz do tecido ±tol (circular 0..179) E muito saturado
  @hue_tol 18
  @vibrant_sat 150
  # porta de saturação na saliência (tira pele/parede de baixa sat)
  @sat_gate 130
  # acima desta fração do quadro a cor-vibrante é luz monocromática → desliga
  @mono_frac 0.40

  @denoise_div 150
  # ponte vertical: linha 1 × (altura/4) — alta o bastante p/ cruzar o tronco
  @bridge_div 4
  @smooth_div 110

  # reconstrução: kernel que separa "fino" (tecido) de "grosso" (mancha)
  @blob_div 13
  # semente: corrida vertical mínima (altura/12) — só fita pendurada semeia
  @seed_vrun_div 12
  @grow_div 40
  @grow_iters 22

  # geometria final: alto, com área mínima, E alcançando o topo (invariante)
  @min_height_frac 0.18
  @min_area_frac 0.0025
  @top_frac 0.28

  @apparatus_class 19

  @doc """
  Máscara u8 `{h, w}` (0|255) do tecido.

    * `full_fg_u8` — foreground COMPLETO do U²-Net (idealmente `u2netp`).
    * `labels` — rótulos ATR (pra subtrair a pessoa).
    * `rgb` — a imagem (saliência ∩ saturação + cor); `nil` → só saliência.
    * `color` — `{r,g,b}` da cor real do tecido na foto; `nil` desliga a cor.
  """
  @spec detect(Nx.Tensor.t(), Nx.Tensor.t(), Nx.Tensor.t() | nil, Layers.rgb() | nil) ::
          Nx.Tensor.t()
  def detect(full_fg_u8, labels, rgb \\ nil, color \\ nil) do
    {h, w} = Nx.shape(labels)
    person = person_mask(labels, w)

    full_fg_u8
    |> Nx.greater(0)
    |> silk_evidence(rgb, normalize_color(color), h, w)
    |> Nx.logical_and(Nx.logical_not(person))
    |> morph(:open, ellipse(round(w / @denoise_div)))
    |> morph(:close, vline(round(h / @bridge_div)))
    |> morph(:close, ellipse(round(w / @smooth_div)))
    |> keep_thin_ribbons(h, w)
    |> keep_top_anchored(h, w)
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
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

  defp person_mask(labels, w) do
    Nx.logical_or(
      dilate_b(Nx.greater(labels, 0), ellipse(round(w / @person_dilate_div))),
      dilate_b(Nx.equal(labels, @hair_class), ellipse(round(w / @hair_dilate_div)))
    )
  end

  # sem imagem → só a saliência (não dá pra medir saturação/cor)
  defp silk_evidence(fg, nil, _color, _h, _w), do: fg

  # núcleo = (saliência ∩ saturado) ∪ cor-vibrante
  defp silk_evidence(fg, rgb, color, h, w) do
    [hue_c, sat_c, _v] = rgb |> to_hsv() |> Evision.split()
    sat = sat_c |> Evision.Mat.to_nx(Nx.BinaryBackend)
    core = Nx.logical_and(fg, Nx.greater(sat, @sat_gate))
    Nx.logical_or(core, vibrant_color(hue_c, sat, color, h, w))
  end

  defp vibrant_color(_hue_c, _sat, nil, h, w), do: empty(h, w)

  defp vibrant_color(hue_c, sat, {_, _, _} = color, h, w) do
    target = hue_of(color)
    hue = hue_c |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.as_type(:s32)
    dist = Nx.abs(Nx.subtract(hue, target))
    circular = Nx.min(dist, Nx.subtract(180, dist))
    vibrant = Nx.logical_and(Nx.less_equal(circular, @hue_tol), Nx.greater(sat, @vibrant_sat))
    # guarda anti-monocromático
    if Nx.to_number(Nx.sum(vibrant)) / (h * w) > @mono_frac, do: empty(h, w), else: vibrant
  end

  # PROTEÇÃO CONTRA MANCHAS por reconstrução: semeia nas fitas verticais finas e
  # cresce DENTRO da parte fina (não da máscara cheia) — a fita segue ao longo de
  # si, mas o crescimento para num blob gordo (parede, objeto, membro).
  defp keep_thin_ribbons(mask, h, w) do
    r = ellipse(round(w / @blob_div))
    thick = morph(mask, :open, r)
    thin = Nx.logical_and(mask, Nx.logical_not(dilate_b(thick, r)))
    seeds = morph(thin, :open, vline(round(h / @seed_vrun_div)))
    grow = ellipse(round(w / @grow_div))
    Enum.reduce(1..@grow_iters, seeds, fn _, acc -> Nx.logical_and(dilate_b(acc, grow), thin) end)
  end

  # INVARIANTE: o tecido pende do topo. Fica só componente alto, de área mínima,
  # cujo bbox COMEÇA no topo (≤ @top_frac). stats: colunas [x, y, largura, alt, área].
  defp keep_top_anchored(mask, h, w) do
    {_n, lbls, stats, _c} = Evision.connectedComponentsWithStats(to_mat(mask))
    s = Evision.Mat.to_nx(stats, Nx.BinaryBackend)
    {y, bh, area} = {s[[.., 1]], s[[.., 3]], s[[.., 4]]}

    keep =
      Nx.greater_equal(bh, round(h * @min_height_frac))
      |> Nx.logical_and(Nx.greater_equal(area, round(h * w * @min_area_frac)))
      |> Nx.logical_and(Nx.less_equal(y, round(h * @top_frac)))
      |> Nx.as_type(:u8)
      |> Nx.put_slice([0], Nx.tensor([0], type: :u8))

    lbls_nx = lbls |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.as_type(:s64)
    keep |> Nx.take(lbls_nx) |> Nx.greater(0)
  end

  # cor vem como {r,g,b} (struct) ou [r,g,b] (manifest/JSON); nil = sem pista
  defp normalize_color([r, g, b]), do: {r, g, b}
  defp normalize_color({_, _, _} = c), do: c
  defp normalize_color(_), do: nil

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

  # ── morfologia (máscara booleana ↔ Evision) ──────────────────────
  defp empty(h, w), do: Nx.broadcast(0, {h, w}) |> Nx.greater(1)
  defp to_mat(m), do: m |> Nx.multiply(255) |> Nx.as_type(:u8) |> Evision.Mat.from_nx()
  defp of_mat(mat), do: mat |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.greater(0)

  defp morph(m, :open, k),
    do: of_mat(Evision.morphologyEx(to_mat(m), Evision.Constant.cv_MORPH_OPEN(), k))

  defp morph(m, :close, k),
    do: of_mat(Evision.morphologyEx(to_mat(m), Evision.Constant.cv_MORPH_CLOSE(), k))

  defp dilate_b(m, k), do: of_mat(Evision.dilate(to_mat(m), k))

  defp ellipse(s) do
    k = max(s, 1)
    Evision.getStructuringElement(Evision.Constant.cv_MORPH_ELLIPSE(), {k, k})
  end

  # linha VERTICAL (largura 1 × altura len) — não funde faixas lado a lado
  defp vline(len),
    do: Evision.getStructuringElement(Evision.Constant.cv_MORPH_RECT(), {1, max(len, 1)})
end
