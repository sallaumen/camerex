defmodule Camerex.Parser.Hair do
  @moduledoc """
  Fallback de detecção de CABELO por cor + TEXTURA + silhueta, para poses
  (acrobáticas, de costas, invertidas) e luz colorida em que o SegFormer ATR não
  enxerga cabeça nenhuma (classe 2 = 0% — medido nas fotos aéreas do Lucas). Roda
  SÓ quando o ATR falha (`present?/1` falso) E o usuário indica a cor: preserva o
  parsing do ATR nos casos frontais que ele acerta, conserta só onde ele cega.

  **Dois eixos, não um.** Sob luz monocromática a COR não basta: cabelo creme e
  pele iluminada convergem pra quase a mesma cor (e o matiz colapsa todo no
  vermelho — por isso distância em Lab, não HSV). O 2º eixo é a TEXTURA: cabelo é
  fio sobre fio (alta variância local da luminância), pele é lisa (baixa). A
  interseção das duas separa o cabelo da pele da mesma cor — o que a cor sozinha
  não faz (era a "mistura" em que ombro/tronco viravam cabelo).

  Pipeline (validado na foto real):
    1. **Evidência** = silhueta(u2net, maior componente — inclui o cabelo) ∩
       `dist_Lab(cor) < tol` ∩ `textura > limiar`. A cor entra em escala u8
       (senão o OpenCV usa Lab float [0..100] e a distância vira lixo).
    2. **close** consolida os fragmentos do cacho numa massa.
    3. **maior componente NÃO-FITA**: o cabelo é UM cacho compacto. "Todos os
       compactos" misturava pele; o simples "maior" pegava o TECIDO aéreo — que,
       da mesma cor sob luz monocromática, entra na silhueta como fita vertical
       longa. Então descarta fitas (alt/larg alto) e pega o maior cacho restante.
    4. **preenchimento de buracos**: tudo que não é fundo-conectado-à-borda vira
       cabelo — fecha as sombras internas entre mechas sem expandir a borda (logo
       sem re-pegar pele), dando um cacho sólido.
    5. **área mínima**: maior componente ínfimo → não há cabelo da cor → vazio.

  Vira a classe 2 (hair) nos labels. Puro (quem roda o U²-Net é o chamador).
  """

  @hair_class 2

  # SENSIBILIDADE (0..1, default 0.5) afrouxa/aperta JUNTOS a distância de cor e
  # o limiar de textura (recall ↔ precisão): subir pega mais do cacho (e mais
  # risco de pele); descer fica mais limpo. Em 0.5: tol Lab 20, textura 9.
  defp lab_tol(s), do: round(14 + s * 12)
  defp tex_thr(s), do: round(13 - s * 8)
  # limiar do Mahalanobis² do modelo de região (em desvios²): apertado de
  # propósito — pega só as tonalidades centrais do cabelo (as sombras escuras, ~
  # cor da roupa, ficariam de fora e seriam re-preenchidas pelo fill_holes)
  defp maha_thr(s), do: 2.0 + s * 3.0

  # janela do desvio-padrão local (textura) da luminância
  @tex_window 7
  # regularização da covariância do modelo de região (só anti-singular; valor
  # alto alargaria o elipsoide e faria o modelo aceitar cor demais)
  @cov_reg 1.0
  # close de consolidação (~w/40 ≈ 13px em 512) junta a evidência esparsa de cor
  @consolidate_div 40
  # maior componente menor que isto (do quadro) = não há cabelo da cor → vazio
  @min_area_frac 0.0015
  # componente mais alto que largo na razão (alt/larg) acima disto é FITA (tecido
  # aéreo), não cacho — descartado da escolha do cabelo
  @max_aspect 3.5

  # classes ATR sobrescritíveis pelo cabelo: fundo + roupas/acessórios (a cabeça
  # em pose aérea é mis-rotulada como vestido/calça). NÃO inclui membros, rosto e
  # sapatos (12..15, 11, 9, 10) — onde o ATR acerta, o cabelo não invade.
  @overwritable [0, 4, 5, 6, 7, 8, 16, 17]

  # o ATR "achou cabelo" se a classe 2 cobre mais que isto do quadro
  @hair_present_min 0.003

  # eyedropper: raio da janela de amostra (~w/25 ≈ 20px em 512) e nº mínimo de
  # pixels texturizados nela pra valer (abaixo disso = clique no vazio liso)
  @sample_radius_div 25
  @sample_min_px 16

  @doc """
  Máscara u8 `{h, w}` (0|255) do cabelo.

    * `person_fg_u8` — silhueta da PESSOA (maior componente do U²-Net; inclui o
      cabelo). A cor e a textura restringem ao cacho dentro dela.
    * `labels` — rótulos ATR (usados só para o shape `{h, w}`).
    * `rgb` — a imagem (cor e textura precisam dela); `nil` → máscara vazia.
    * `color` — `{r, g, b}` (1 cor / eyedropper) OU um MODELO `%{mu, cov_inv}` de
      `learn_model/2` (região marcada, capta as várias tonalidades); `nil` →
      máscara vazia (sem pista, este fallback não dispara).
    * `opts` — `:sensitivity` (0..1, default 0.5): recall ↔ precisão.
  """
  @spec detect(
          Nx.Tensor.t(),
          Nx.Tensor.t(),
          Nx.Tensor.t() | nil,
          tuple() | list() | map() | nil,
          keyword()
        ) ::
          Nx.Tensor.t()
  def detect(person_fg_u8, labels, rgb \\ nil, color \\ nil, opts \\ []) do
    {h, w} = Nx.shape(labels)
    s = opts |> Keyword.get(:sensitivity, 0.5) |> clamp01()

    person_fg_u8
    |> Nx.greater(0)
    |> hair_evidence(rgb, normalize_color(color), s)
    |> morph(:close, ellipse(round(w / @consolidate_div)))
    |> hair_blob(h, w)
    |> fill_holes(h, w)
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
  end

  @doc """
  `true` se o ATR já rotulou cabelo suficiente (classe 2 cobre mais que 0.3% do
  quadro). Os pipelines decidem com isto: presente → confia no ATR; ausente
  (pose aérea/de costas → ~0%) → roda o fallback por cor, se houver cor indicada.
  """
  @spec present?(Nx.Tensor.t()) :: boolean()
  def present?(labels) do
    {h, w} = Nx.shape(labels)
    Nx.to_number(Nx.sum(Nx.equal(labels, @hair_class))) / (h * w) > @hair_present_min
  end

  @doc """
  Injeta a classe `2` (hair) onde HÁ cabelo E o ATR rotulou fundo ou roupa (a
  cabeça em pose aérea cai em vestido/calça). Não invade membros/rosto/sapatos.
  """
  @spec into_labels(Nx.Tensor.t(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def into_labels(labels, hair_u8) do
    where = Nx.logical_and(Nx.greater(hair_u8, 0), overwritable(labels))
    Nx.select(where, Nx.broadcast(Nx.u8(@hair_class), Nx.shape(labels)), labels)
  end

  @doc """
  Amostra a cor do cabelo numa janela ao redor de um ponto (frações `{xf, yf}` em
  0..1 — o clique do usuário na prévia). Usa só os pixels TEXTURIZADOS da janela
  (o cabelo, não o fundo liso), então o clique tolera imprecisão. Devolve
  `{r, g, b}`, ou `nil` se a janela não tiver textura de cabelo (clique no vazio).
  """
  @spec sample_color(Nx.Tensor.t(), {number(), number()}, keyword()) ::
          {0..255, 0..255, 0..255} | nil
  def sample_color(rgb, {xf, yf}, opts \\ []) do
    {h, w, _} = Nx.shape(rgb)
    r = Keyword.get(opts, :radius, round(w / @sample_radius_div))
    cx = (clamp01(xf) * (w - 1)) |> round()
    cy = (clamp01(yf) * (h - 1)) |> round()
    {x0, y0} = {max(cx - r, 0), max(cy - r, 0)}
    {x1, y1} = {min(cx + r, w - 1), min(cy + r, h - 1)}

    win = rgb[[y0..y1, x0..x1, 0..2]] |> Nx.as_type(:f32)
    std = local_std(rgb)[[y0..y1, x0..x1]]
    textured = Nx.greater(std, tex_thr(0.5))
    cnt = textured |> Nx.sum() |> Nx.to_number()

    if cnt >= @sample_min_px, do: window_color(win, textured, cnt), else: nil
  end

  defp window_color(win, textured, cnt) do
    sel = textured |> Nx.new_axis(-1) |> Nx.broadcast(Nx.shape(win))

    [r, g, b] =
      sel
      |> Nx.select(win, Nx.tensor(0.0))
      |> Nx.sum(axes: [0, 1])
      |> Nx.divide(cnt)
      |> Nx.round()
      |> Nx.as_type(:s32)
      |> Nx.to_flat_list()

    {r, g, b}
  end

  @doc """
  Aprende um MODELO de cor do cabelo de uma REGIÃO marcada (retângulo em frações
  `{x0, y0, x1, y1}`, 0..1): média + inversa da covariância no Lab dos pixels
  TEXTURIZADOS da região (o cabelo, não o fundo liso). A covariância capta a
  distribuição de tonalidades — não 1 cor só (resolve "ainda tem muitas cores no
  cabelo"). É serializável e invariante à posição, então serve foto E vídeo (o
  mesmo modelo segue o cabelo frame a frame). Devolve `%{mu: [3], cov_inv: [9]}`,
  ou `nil` se a região não tiver textura de cabelo.
  """
  @spec learn_model(Nx.Tensor.t(), {number(), number(), number(), number()}) ::
          %{mu: [float()], cov_inv: [float()]} | nil
  def learn_model(rgb, {x0f, y0f, x1f, y1f}) do
    {h, w, _} = Nx.shape(rgb)
    {x0, x1} = {px(min(x0f, x1f), w), px(max(x0f, x1f), w)}
    {y0, y1} = {px(min(y0f, y1f), h), px(max(y0f, y1f), h)}

    weight = local_std(rgb) |> Nx.greater(tex_thr(0.5)) |> Nx.as_type(:f32)
    crop_lab = to_lab(rgb)[[y0..y1, x0..x1, 0..2]]
    crop_w = weight[[y0..y1, x0..x1]]
    wsum = crop_w |> Nx.sum() |> Nx.to_number()

    if wsum >= @sample_min_px, do: build_model(crop_lab, crop_w, wsum), else: nil
  end

  defp px(f, dim), do: (clamp01(f) * (dim - 1)) |> round()

  # média e inversa da covariância (Lab) ponderadas pela máscara de textura
  defp build_model(crop_lab, crop_w, wsum) do
    {bh, bw, _} = Nx.shape(crop_lab)
    w3 = Nx.new_axis(crop_w, -1)
    mu = crop_lab |> Nx.multiply(w3) |> Nx.sum(axes: [0, 1]) |> Nx.divide(wsum)
    ctr = Nx.subtract(crop_lab, Nx.reshape(mu, {1, 1, 3}))
    fc = Nx.reshape(ctr, {bh * bw, 3})
    fw = ctr |> Nx.multiply(w3) |> Nx.reshape({bh * bw, 3})
    cov = fw |> Nx.transpose() |> Nx.dot(fc) |> Nx.divide(wsum)
    cov_inv = Nx.LinAlg.invert(Nx.add(cov, Nx.multiply(Nx.eye(3), @cov_reg)))
    %{mu: Nx.to_flat_list(mu), cov_inv: Nx.to_flat_list(cov_inv)}
  end

  defp clamp01(s) when is_number(s), do: s |> max(0.0) |> min(1.0)
  defp clamp01(_), do: 0.5

  # evidência = silhueta ∩ cor ∩ textura (sem imagem ou sem cor/modelo → vazia)
  defp hair_evidence(person, nil, _color, _s), do: false_like(person)
  defp hair_evidence(person, _rgb, nil, _s), do: false_like(person)

  defp hair_evidence(person, rgb, color, s) do
    near = near_color(to_lab(rgb), color, s)
    textured = Nx.greater(local_std(rgb), tex_thr(s))
    person |> Nx.logical_and(near) |> Nx.logical_and(textured)
  end

  # 1 cor: distância euclidiana esférica no Lab (caso simples / eyedropper de clique)
  defp near_color(lab, {_, _, _} = color, s),
    do: Nx.less(color_dist(lab, lab_of(color)), lab_tol(s))

  # MODELO da região: distância de Mahalanobis (a covariância capta a distribuição
  # de tonalidades do cabelo — várias cores, não uma)
  defp near_color(lab, %{mu: mu, cov_inv: ci}, s) do
    diff = Nx.subtract(lab, mu |> Nx.tensor(type: :f32) |> Nx.reshape({1, 1, 3}))
    ci_t = ci |> Nx.tensor(type: :f32) |> Nx.reshape({3, 3})
    d2 = Nx.sum(Nx.multiply(Nx.dot(diff, ci_t), diff), axes: [-1])
    Nx.less(d2, maha_thr(s))
  end

  # distância euclidiana no Lab (escala u8) a cada pixel até a cor alvo
  defp color_dist(lab, target) do
    lab
    |> Nx.subtract(Nx.reshape(target, {1, 1, 3}))
    |> Nx.pow(2)
    |> Nx.sum(axes: [-1])
    |> Nx.sqrt()
  end

  # textura = desvio-padrão local da luminância numa janela: sqrt(E[x²] − E[x]²)
  defp local_std(rgb) do
    gray = to_gray(rgb)
    mean = box_blur(gray)

    box_blur(Nx.multiply(gray, gray))
    |> Nx.subtract(Nx.multiply(mean, mean))
    |> Nx.max(0.0)
    |> Nx.sqrt()
  end

  # o blob do cabelo: maior componente que NÃO é fita vertical longa (o tecido
  # aéreo, da mesma cor sob luz monocromática, entra na silhueta como fita).
  # Piso de área descarta lixo e o caso "não há cabelo da cor". stats: [x, y,
  # larg, alt, área].
  defp hair_blob(mask, h, w) do
    {n, lbls, stats, _c} = mask |> to_mat() |> Evision.connectedComponentsWithStats()

    if n <= 1 do
      false_like(mask)
    else
      st = Evision.Mat.to_nx(stats, Nx.BinaryBackend)
      {bw, bh, area} = {st[[.., 2]], st[[.., 3]], st[[.., 4]]}
      aspect = Nx.divide(bh, Nx.max(bw, 1))

      eligible =
        Nx.less(aspect, @max_aspect)
        |> Nx.logical_and(Nx.greater_equal(area, round(h * w * @min_area_frac)))
        |> Nx.put_slice([0], Nx.tensor([0], type: {:u, 8}))

      scored =
        Nx.select(eligible, area, Nx.broadcast(Nx.tensor(0, type: Nx.type(area)), Nx.shape(area)))

      best = scored |> Nx.argmax() |> Nx.to_number()

      if Nx.to_number(scored[best]) > 0 do
        lbls |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.equal(best)
      else
        false_like(mask)
      end
    end
  end

  # preenche os buracos INTERNOS do cacho: rotula o complemento (fundo + buracos)
  # e adiciona de volta tudo que NÃO toca a borda do quadro (= buraco cercado).
  # Vetorizado pelos bounding-boxes — um componente toca a borda se x=0, y=0,
  # x+larg=w ou y+alt=h. stats: colunas [x, y, larg, alt, área].
  defp fill_holes(mask, h, w) do
    {n, lbls, stats, _c} =
      mask |> Nx.logical_not() |> to_mat() |> Evision.connectedComponentsWithStats()

    if n <= 1 do
      mask
    else
      st = Evision.Mat.to_nx(stats, Nx.BinaryBackend)
      {x, y, bw, bh} = {st[[.., 0]], st[[.., 1]], st[[.., 2]], st[[.., 3]]}

      touches =
        Nx.equal(x, 0)
        |> Nx.logical_or(Nx.equal(y, 0))
        |> Nx.logical_or(Nx.equal(Nx.add(x, bw), w))
        |> Nx.logical_or(Nx.equal(Nx.add(y, bh), h))

      # buraco = componente do complemento que NÃO toca a borda; o label 0 (a
      # própria máscara) é zerado — já está coberto pelo OR final
      hole =
        touches
        |> Nx.logical_not()
        |> Nx.as_type(:u8)
        |> Nx.put_slice([0], Nx.tensor([0], type: :u8))

      lbls_nx = lbls |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.as_type(:s64)
      Nx.logical_or(mask, hole |> Nx.take(lbls_nx) |> Nx.greater(0))
    end
  end

  defp overwritable(labels) do
    Enum.reduce(@overwritable, false_like(labels), fn c, acc ->
      Nx.logical_or(acc, Nx.equal(labels, c))
    end)
  end

  # cor vem como {r,g,b} (struct) ou [r,g,b] (manifest/JSON); nil = sem pista
  # modelo da região (átomos do struct ou string-keyed do manifest) ou 1 cor
  defp normalize_color(%{mu: mu, cov_inv: ci}), do: %{mu: mu, cov_inv: ci}
  defp normalize_color(%{"mu" => mu, "cov_inv" => ci}), do: %{mu: mu, cov_inv: ci}
  defp normalize_color([r, g, b]), do: {r, g, b}
  defp normalize_color({_, _, _} = c), do: c
  defp normalize_color(_), do: nil

  defp to_gray(rgb) do
    rgb
    |> Evision.Mat.from_nx_2d()
    |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2GRAY())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.as_type(:f32)
  end

  defp box_blur(nxf) do
    nxf
    |> Evision.Mat.from_nx_2d()
    |> Evision.blur({@tex_window, @tex_window})
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  # Lab da imagem (escala u8 [0..255], como a cor alvo)
  defp to_lab(rgb) do
    rgb
    |> Evision.Mat.from_nx_2d()
    |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2Lab())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.as_type(:f32)
  end

  # cor alvo em Lab: u8 (NÃO float) pra casar a escala da imagem
  defp lab_of({r, g, b}) do
    Nx.tensor([r, g, b], type: :u8)
    |> Nx.reshape({1, 1, 3})
    |> Evision.Mat.from_nx_2d()
    |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2Lab())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.as_type(:f32)
    |> Nx.reshape({3})
  end

  # ── morfologia (máscara booleana ↔ Evision) ──────────────────────
  defp false_like(t), do: Nx.broadcast(Nx.tensor(false), Nx.shape(t))
  defp to_mat(m), do: m |> Nx.multiply(255) |> Nx.as_type(:u8) |> Evision.Mat.from_nx()
  defp of_mat(mat), do: mat |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.greater(0)

  defp morph(m, :close, k),
    do: of_mat(Evision.morphologyEx(to_mat(m), Evision.Constant.cv_MORPH_CLOSE(), k))

  defp ellipse(s) do
    k = max(s, 1)
    Evision.getStructuringElement(Evision.Constant.cv_MORPH_ELLIPSE(), {k, k})
  end
end
