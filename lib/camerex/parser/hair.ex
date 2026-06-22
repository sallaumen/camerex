defmodule Camerex.Parser.Hair do
  @moduledoc """
  Fallback de detecção de CABELO por cor + silhueta + geometria, para poses
  (acrobáticas, de costas, invertidas) e luz colorida em que o SegFormer ATR
  não enxerga cabeça nenhuma (classe 2 = 0% — medido nas fotos aéreas do Lucas).
  Roda SÓ quando o ATR falha E o usuário indica a cor do cabelo: preserva o
  parsing do ATR nos casos frontais que ele acerta, conserta só onde ele cega.

  Por que NÃO matiz (como o tecido faz): sob luz monocromática o matiz de tudo
  colapsa no vermelho — pele, parede e cabelo caem no mesmo ângulo de cor. A
  separação vem da **distância no espaço Lab** (cor real completa) a partir da
  cor indicada; luminância e saturação não colapsam, então o cabelo creme-claro
  ainda se distingue da pele avermelhada. Pipeline (validado na foto real):

    1. **Evidência** = silhueta da pessoa ∩ `dist_Lab(cor indicada) < tol`. A
       silhueta (U²-Net, maior componente) já inclui o cabelo; a cor restringe
       ao cacho. A cor entra em escala **u8** (senão o OpenCV usa Lab float
       `[0..100]` e a distância vira lixo).
    2. **Consolidação** (`close`): cabelo é MASSA texturizada (highlights +
       sombras), então a cor casa em fragmentos — o close junta o cacho numa
       massa antes de limpar.
    3. **Denoise** (`open`): tira o vazamento esparso pra pele clara da borda.
    4. **Geometria**: fica componente compacto (não alongado) e de área mínima
       — o cacho; descarta restos de vazamento.

  Vira a classe 2 (hair) nos labels. Puro (quem roda o U²-Net é o chamador).
  """

  @hair_class 2

  # SENSIBILIDADE (0..1, default 0.5) afrouxa/aperta a distância de cor
  # (recall ↔ precisão): subir pega mais do cacho (e mais risco de pele);
  # descer fica mais limpo. Em 0.5 dá tol 20 (o valor validado).
  defp lab_tol(s), do: round(14 + s * 12)

  # close ~ w/46 (≈11px em 512) consolida a textura; open ~ w/170 (≈3px) limpa
  @consolidate_div 46
  @denoise_div 170

  # geometria: cacho compacto (área/bbox) e de área mínima relativa ao quadro
  @min_area_frac 0.0015
  @min_extent 0.28

  # classes ATR sobrescritíveis pelo cabelo: fundo + roupas/acessórios (a cabeça
  # em pose aérea é mis-rotulada como vestido/calça). NÃO inclui membros, rosto e
  # sapatos (12..15, 11, 9, 10) — onde o ATR acerta, o cabelo não invade.
  @overwritable [0, 4, 5, 6, 7, 8, 16, 17]

  # o ATR "achou cabelo" se a classe 2 cobre mais que isto do quadro
  @hair_present_min 0.003

  @doc """
  Máscara u8 `{h, w}` (0|255) do cabelo.

    * `person_fg_u8` — silhueta da PESSOA (maior componente do U²-Net; inclui o
      cabelo). `keep_*` restringem ao cacho dentro dela.
    * `labels` — rótulos ATR (usados só para o shape `{h, w}`).
    * `rgb` — a imagem (a distância de cor precisa dela); `nil` → máscara vazia.
    * `color` — `{r, g, b}` da cor real do cabelo na foto; `nil` → máscara vazia
      (sem pista, este fallback não dispara).
    * `opts` — `:sensitivity` (0..1, default 0.5): recall ↔ precisão da cor.
  """
  @spec detect(
          Nx.Tensor.t(),
          Nx.Tensor.t(),
          Nx.Tensor.t() | nil,
          tuple() | list() | nil,
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
    |> morph(:open, ellipse(round(w / @denoise_div)))
    |> keep_compact(h, w)
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
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
  `true` se o ATR já rotulou cabelo suficiente (classe 2 cobre mais que 0.3% do
  quadro). Os pipelines decidem com isto: presente → confia no ATR; ausente
  (pose aérea/de costas → ~0%) → roda o fallback por cor, se houver cor indicada.
  """
  @spec present?(Nx.Tensor.t()) :: boolean()
  def present?(labels) do
    {h, w} = Nx.shape(labels)
    Nx.to_number(Nx.sum(Nx.equal(labels, @hair_class))) / (h * w) > @hair_present_min
  end

  defp clamp01(s) when is_number(s), do: s |> max(0.0) |> min(1.0)
  defp clamp01(_), do: 0.5

  # sem imagem ou sem cor indicada → este fallback não tem como discriminar
  defp hair_evidence(person, nil, _color, _s), do: Nx.logical_and(person, false_like(person))
  defp hair_evidence(person, _rgb, nil, _s), do: Nx.logical_and(person, false_like(person))

  defp hair_evidence(person, rgb, {_, _, _} = color, s) do
    dist = color_dist(to_lab(rgb), lab_of(color))
    Nx.logical_and(person, Nx.less(dist, lab_tol(s)))
  end

  # distância euclidiana no Lab (escala u8) a cada pixel até a cor alvo
  defp color_dist(lab, target) do
    lab
    |> Nx.subtract(Nx.reshape(target, {1, 1, 3}))
    |> Nx.pow(2)
    |> Nx.sum(axes: [-1])
    |> Nx.sqrt()
  end

  # mantém componentes compactos (área/bbox alta) e de área mínima — o cacho;
  # descarta restos de vazamento (finos/alongados). stats: [x, y, larg, alt, área].
  defp keep_compact(mask, h, w) do
    {_n, lbls, stats, _c} = Evision.connectedComponentsWithStats(to_mat(mask))
    st = Evision.Mat.to_nx(stats, Nx.BinaryBackend)
    {bw, bh, area} = {st[[.., 2]], st[[.., 3]], st[[.., 4]]}
    extent = Nx.divide(area, Nx.max(Nx.multiply(bw, bh), 1))

    keep =
      area
      |> Nx.greater_equal(round(h * w * @min_area_frac))
      |> Nx.logical_and(Nx.greater_equal(extent, @min_extent))
      |> Nx.as_type(:u8)
      |> Nx.put_slice([0], Nx.tensor([0], type: :u8))

    lbls_nx = lbls |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.as_type(:s64)
    keep |> Nx.take(lbls_nx) |> Nx.greater(0)
  end

  defp overwritable(labels) do
    Enum.reduce(@overwritable, false_like(labels), fn c, acc ->
      Nx.logical_or(acc, Nx.equal(labels, c))
    end)
  end

  # cor vem como {r,g,b} (struct) ou [r,g,b] (manifest/JSON); nil = sem pista
  defp normalize_color([r, g, b]), do: {r, g, b}
  defp normalize_color({_, _, _} = c), do: c
  defp normalize_color(_), do: nil

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

  defp morph(m, :open, k),
    do: of_mat(Evision.morphologyEx(to_mat(m), Evision.Constant.cv_MORPH_OPEN(), k))

  defp morph(m, :close, k),
    do: of_mat(Evision.morphologyEx(to_mat(m), Evision.Constant.cv_MORPH_CLOSE(), k))

  defp ellipse(s) do
    k = max(s, 1)
    Evision.getStructuringElement(Evision.Constant.cv_MORPH_ELLIPSE(), {k, k})
  end
end
