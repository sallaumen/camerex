defmodule Camerex.Neon.Layered do
  @moduledoc """
  Cor-por-parte (look de tubo de LED), compartilhado por foto e vídeo.

  A partir dos rótulos semânticos do `Camerex.Parser`, produz duas coisas
  puras (tensor entra, tensor sai):

    * `line_art/2` — a ARTE-DE-LINHA: contorno de cada parte semântica a partir
      da máscara SUAVE (silhueta externa + fronteiras entre partes). Como vem da
      máscara e não de um detector de bordas na foto, não carrega o chuvisco/
      "quadrados" que a textura do tecido gera no Canny — só curvas contínuas e
      fluidas, que é o que dá o acabamento de tubo de LED.
    * `color_field/3` — o CAMPO DE COR mesclado por grupo (pele/cabelo/roupa/
      acessórios): cada grupo vira um peso suave borrado e as interseções se
      misturam proporcionalmente (num/den), dando o sangramento de cor do LED.

  Foto chama as duas uma vez; vídeo chama por frame e estabiliza no tempo
  (rastro na arte-de-linha, EMA no campo de cor).
  """

  alias Camerex.Parser.Layers

  # componentes de um rótulo menores que esta fração da imagem são ilhas de
  # rotulagem espúria (um patch de "pele" no meio da roupa) — descartadas antes
  # de virar contorno, senão pingam bolhinhas soltas na arte.
  @island_area_frac 0.0004

  # contornos: loops ISOLADOS menores que esta fração viram "bolinhas" (anel de
  # uma ilha que sobrou). A silhueta e as fronteiras reais são um componente
  # enorme conectado, então só os ovais soltos caem.
  @contour_min_area_frac 0.0005

  # detalhe interno: o mean-shift POSTERIZA (achata a imagem em regiões de cor
  # chapada) antes do Canny, então a textura do tecido nem vira borda — o Canny
  # traça só fronteiras de região (cabelo em mechas, vincos, perfis), sem os
  # "quadrados". Roda numa versão reduzida (o mean-shift é caro). Parâmetros
  # FIXOS — o mapa de traços é sempre o mesmo, rico.
  @ms_work_width 1600
  @ms_spatial 16
  @ms_color 20
  @canny_lo 50
  @canny_hi 130
  # o slider `detail` controla QUANTOS traços aparecem por TAMANHO: mantém só os
  # componentes acima de um mínimo que CAI com o detalhe — detalhe baixo = só os
  # traços longos (poucos), detalhe alto = inclui os curtos (muitos). Como há
  # muitos traços de tamanhos variados, o número cresce gradual (não é opacidade,
  # é quantidade). curva > 1 = entra devagar no começo. O mínimo é FRAÇÃO da área
  # da imagem (invariante à resolução).
  @stroke_max_frac 0.0006
  @stroke_curve 1.3
  # a PELE (rosto/braços/pernas) deve ler LISA — tubo de LED, não escama. O
  # problema: a definição muscular e as sombras dos membros são gradientes REAIS
  # (não textura de tecido), então sobrevivem ao mean-shift e viram um chuvisco
  # denso de traços curtos justo na pele. Roupa e cabelo, ao contrário, GANHAM
  # com detalhe (dobras, mechas). Solução: o detalhe interno na pele roda com um
  # `detail` AMORTECIDO (só os traços longos — separação de membro, sombra-mestra
  # — sobrevivem); o resto da figura mantém o `detail` cheio do usuário.
  @skin_detail_damp 0.35
  # CLAHE no canal de valor (V) antes do mean-shift: realça o micro-contraste
  # LOCAL, então os vincos de roupa preta (e o boné) — que o tecido escuro
  # esconde — sobem acima do raio de cor do mean-shift e viram traço. Em região
  # já clara o efeito é pequeno; a posterização do mean-shift segura a textura.
  @shadow_clip 4.0
  # supressão por densidade: faxina final da textura MUITO densa (renda, paetê)
  # que sobrevive ao mean-shift. O resto já está limpo, então pode ser firme.
  @density_sigma_div 60.0
  @density_threshold 0.34
  # preenchimento: DUAS opacidades independentes — `color` (intensidade do tom
  # chapado da parte) e `texture` (quanto a LUMINÂNCIA da foto modula por cima,
  # dando volume/dobras). texture baixo = quase chapado mesmo com a cor forte.
  # gama < 1 levanta os meios-tons da textura. O fill é confinado à figura
  # ERODIDA (`@fill_inset_div`), pra não vazar pro chão/fundo (o campo de cor é
  # borrado e sangraria pra fora).
  @fill_gamma 0.8
  @fill_inset_div 150
  # blur do campo de cor: divisor menor = blur maior = mais sangramento entre
  # cores nas fronteiras. Estreito o bastante pra a cor não vazar de uma parte
  # pra outra (ex.: pele clara invadindo o cabelo), mas ainda com transição suave.
  @field_blur_div 200
  # suavização "tubo de LED": o Canny cru sai em escada de pixel, quebrado e em
  # zigue-zague (cara de caneta riscando). close fecha as quebras, dilate dá um
  # CORPO ao traço, e o blur anti-aliasa a escada → tubos fluidos e contínuos.
  # norm levanta o brilho do núcleo do tubo (o blur espalha a energia).
  @tube_close 3
  # corpo do tubo (dilate) ∝ largura: ~1px em foto pequena (428w nativo), ~3px a
  # 1200w. Era 3px FIXO — fração enorme numa foto de 428px → contorno gordo. Agora
  # a espessura é a MESMA fração em toda resolução (prévia 480 ≈ export nativo).
  @tube_blur 1.2
  @tube_norm 0.8

  @doc """
  Arte-de-linha `{h, w}` f32 em [0, 1]: combina por máximo duas camadas —

    * **contornos semânticos** (sempre): silhueta + fronteiras entre partes, das
      máscaras suaves. Espinha dorsal limpa, zero textura.
    * **detalhe interno** (opt-in via `detail:` > 0): rosto, mãos, vincos e
      mechas de cabelo, do Canny sobre a imagem POSTERIZADA (mean-shift) — traz
      definição sem os "quadrados" da textura do tecido.

  opts: `detail:` 0..1 (quanto detalhe interno; 0 = só contornos, default 0.5) ·
  `edges:` mapa de bordas posterizadas pré-computado de `posterized_edges/1`
  (o mean-shift é caro e depende SÓ do rgb — a calibragem ao vivo o computa 1×
  por sessão e reusa a cada ajuste, em vez de re-rodar o mean-shift por slider).
  """
  @spec line_art(Nx.Tensor.t(), Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  def line_art(rgb, labels, opts \\ []) do
    detail = Keyword.get(opts, :detail, 0.5)
    edges = Keyword.get(opts, :edges)
    {_h, w, _} = Nx.shape(rgb)

    labels
    |> semantic_contours(w)
    |> Nx.max(internal_detail(rgb, labels, detail, edges))
    |> smooth_tube(w)
  end

  # transforma os traços (u8 0/255) em TUBOS fluidos f32 0..1: fecha quebras,
  # engrossa num corpo (∝ largura) e anti-aliasa a escada de pixel do Canny.
  defp smooth_tube(line_u8, w) do
    line_u8
    |> Evision.Mat.from_nx()
    |> Evision.morphologyEx(Evision.Constant.cv_MORPH_CLOSE(), kernel(@tube_close))
    |> Evision.dilate(kernel(tube_dilate(w)))
    |> Evision.gaussianBlur({0, 0}, @tube_blur)
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.as_type(:f32)
    |> Nx.divide(255.0 * @tube_norm)
    |> Nx.min(1.0)
  end

  # corpo do tubo ∝ largura (ref.: ~3px a 1200w ≈ 0,25%); piso 1px
  defp tube_dilate(w), do: max(round(w / 430), 1)

  # contorno de cada rótulo presente (limpo de ilhas e suavizado) somado por
  # máximo à silhueta externa (contorno da união). Despeckle no fim remove os
  # ovais soltos das ilhas. u8 {h,w}. Sem parte → zeros.
  defp semantic_contours(labels, w) do
    {h, _w} = Nx.shape(labels)

    case present_label_masks(labels, w) do
      [] ->
        Nx.broadcast(Nx.u8(0), {h, w})

      masks ->
        per_label = masks |> Enum.map(&contour/1) |> Enum.reduce(&Nx.max/2)
        silhouette = masks |> Enum.reduce(&Nx.max/2) |> contour()

        per_label
        |> Nx.max(silhouette)
        |> drop_small_components(round(h * w * @contour_min_area_frac))
    end
  end

  # detalhe interno (u8 {h,w}): Canny sobre a imagem posterizada, confinado à
  # figura (erodida), com a textura densa suprimida. detail <= 0 → só contornos.
  # `precomp` = bordas posterizadas já prontas (calibragem ao vivo); nil → computa.
  defp internal_detail(rgb, labels, detail, precomp) do
    {h, w, _} = Nx.shape(rgb)

    if detail <= 0.0 do
      Nx.broadcast(Nx.u8(0), {h, w})
    else
      eroded =
        labels
        |> Nx.greater(0)
        |> Nx.multiply(255)
        |> Nx.as_type(:u8)
        |> Evision.Mat.from_nx()
        |> Evision.erode(kernel(fig_erode(w)))
        |> Evision.Mat.to_nx(Nx.BinaryBackend)

      edges = (precomp || posterized_edges(rgb)) |> Nx.min(eroded)
      skin = Layers.mask(labels, skin_ids())
      area = h * w

      # pele com detalhe amortecido (traços longos só); o resto com detalhe cheio
      on_skin =
        edges |> Nx.min(skin) |> drop_small_components(stroke_min_area(skin_detail(detail), area))

      off_skin =
        edges
        |> Nx.min(Nx.subtract(255, skin))
        |> drop_small_components(stroke_min_area(detail, area))

      on_skin |> Nx.max(off_skin) |> suppress_dense(w)
    end
  end

  # ids do grupo "pele" (derivado do catálogo, sem duplicar a lista)
  defp skin_ids, do: Layers.groups() |> Enum.find(&(&1.key == :skin)) |> Map.fetch!(:ids)

  defp skin_detail(detail), do: detail * @skin_detail_damp

  # tamanho mínimo de traço pro slider: cai com o detalhe. Detalhe baixo →
  # mínimo alto → só os traços longos; detalhe alto → mínimo ~0 → todos.
  defp stroke_min_area(detail, area),
    do: round(area * @stroke_max_frac * :math.pow(1.0 - detail, @stroke_curve)) + 4

  # inset (erode) que confina o detalhe interno à figura, ∝ largura (ímpar): ~3px
  # a 428w (era 5px FIXO — comia mão/pé/joelho em foto pequena), ~7px a 1200w
  defp fig_erode(w), do: max(round(w / 430), 1) * 2 + 1

  @doc """
  Bordas posterizadas `{h, w}` u8 (mean-shift → Canny). Depende SÓ do rgb — caro
  (o mean-shift), então a calibragem ao vivo computa 1× por sessão e passa via
  `line_art(.., edges: _)`, evitando re-rodar o mean-shift a cada slider.
  """
  @spec posterized_edges(Nx.Tensor.t()) :: Nx.Tensor.t()
  # mean-shift (em resolução reduzida, por custo) → Canny → volta ao tamanho
  # cheio. Parâmetros fixos: o mapa de traços é sempre o mesmo (o slider só
  # decide QUANTOS sobrevivem, via stroke_min_area).
  def posterized_edges(rgb) do
    {h, w, _} = Nx.shape(rgb)
    scale = min(@ms_work_width / w, 1.0)
    {tw, th} = {max(round(w * scale), 2), max(round(h * scale), 2)}

    rgb
    |> Evision.Mat.from_nx_2d()
    |> Evision.resize({tw, th}, interpolation: Evision.Constant.cv_INTER_AREA())
    |> lift_shadows()
    |> Evision.pyrMeanShiftFiltering(@ms_spatial, @ms_color)
    |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2GRAY())
    |> Evision.canny(@canny_lo, @canny_hi)
    |> Evision.resize({w, h}, interpolation: Evision.Constant.cv_INTER_NEAREST())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  # equaliza localmente o canal V (HSV): traz os vincos do preto/boné sem mexer
  # no matiz/saturação (a cor fica fiel pro campo de cor por parte).
  defp lift_shadows(rgb_mat) do
    clahe = Evision.createCLAHE(clipLimit: @shadow_clip, tileGridSize: {8, 8})

    [hc, sc, vc] =
      rgb_mat |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2HSV()) |> Evision.split()

    v = Evision.CLAHE.apply(clahe, vc)
    [hc, sc, v] |> Evision.merge() |> Evision.cvtColor(Evision.Constant.cv_COLOR_HSV2RGB())
  end

  # textura densa (renda, paetê) faz uma região de borda DENSA; vinco/feição é
  # esparso. Borra o mapa, apaga onde a densidade local passa do limiar.
  defp suppress_dense(edges, w) do
    density =
      edges
      |> Nx.as_type(:f32)
      |> Nx.divide(255.0)
      |> Evision.Mat.from_nx()
      |> Evision.gaussianBlur({0, 0}, max(w / @density_sigma_div, 5.0))
      |> Evision.Mat.to_nx(Nx.BinaryBackend)

    Nx.multiply(edges, density |> Nx.less(@density_threshold) |> Nx.as_type(:u8))
  end

  @doc """
  Campo de cor `{h, w, 3}` f32 mesclado por grupo semântico. `colors` é
  `%{skin: rgb, hair: rgb, ...}` (use `Layers.default_colors/0` ou
  `Layers.normalize_colors/1`). Sem nenhuma parte → preto.
  """
  @spec color_field(Nx.Tensor.t(), %{atom() => Layers.rgb()}, pos_integer()) :: Nx.Tensor.t()
  def color_field(labels, colors, w) do
    {h, _w} = Nx.shape(labels)

    case present_group_parts(labels, colors) do
      [] -> Nx.broadcast(0.0, {h, w, 3})
      parts -> blended_field(parts, w)
    end
  end

  @doc """
  Camada de PREENCHIMENTO `{h, w, 3}` f32: o `field` (cor por parte) com duas
  opacidades independentes e confinado à figura (de `labels`, erodida).

  opts: `color:` 0..1 (intensidade do tom chapado) · `texture:` 0..1 (quanto a
  luminância da foto modula por cima — dá volume/dobras). texture baixo deixa
  quase chapado mesmo com a cor forte. Componha por máximo sob as linhas.
  """
  @spec texture_fill(Nx.Tensor.t(), Nx.Tensor.t(), Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  def texture_fill(rgb, field, labels, opts \\ []) do
    color_op = Keyword.get(opts, :color, 0.45)
    texture_op = Keyword.get(opts, :texture, 0.15)
    {_h, w, _} = Nx.shape(rgb)

    lum =
      rgb
      |> Evision.Mat.from_nx_2d()
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2GRAY())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)
      |> Nx.as_type(:f32)
      |> Nx.divide(255.0)
      |> Nx.pow(@fill_gamma)

    # tex ~1 (chapado) quando texture_op baixo; = luminância quando alto
    tex = Nx.add(1.0 - texture_op, Nx.multiply(texture_op, lum))
    mask = figure_inset_mask(labels, w)

    field
    |> Nx.multiply(Nx.new_axis(tex, -1))
    |> Nx.multiply(color_op)
    |> Nx.multiply(Nx.new_axis(mask, -1))
  end

  # união das partes ERODIDA (0/1 f32): confina o fill bem dentro da silhueta,
  # então o campo de cor borrado não sangra pro chão/fundo.
  defp figure_inset_mask(labels, w) do
    k = max(round(w / @fill_inset_div), 1)

    labels
    |> Nx.greater(0)
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
    |> Evision.Mat.from_nx()
    |> Evision.erode(kernel(2 * k + 1))
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.greater(0)
    |> Nx.as_type(:f32)
  end

  # --- arte-de-linha (contornos por rótulo individual) ----------------------

  # máscaras suaves dos rótulos individuais presentes (granularidade fina: braço,
  # torso, vestido, colarinho… cada fronteira interna vira uma linha)
  defp present_label_masks(labels, w) do
    {h, _w} = Nx.shape(labels)
    min_area = round(h * w * @island_area_frac)

    labels
    |> present_label_ids()
    |> Enum.map(&clean_smooth_mask(labels, &1, w, min_area))
    |> Enum.reject(&(Nx.to_number(Nx.sum(&1)) == 0))
  end

  defp present_label_ids(labels) do
    labels |> Nx.to_flat_list() |> Enum.uniq() |> Enum.reject(&(&1 == 0)) |> Enum.sort()
  end

  # máscara de UM rótulo: ilhas fora → close (mata a escada do upsample) → blur
  # leve + re-limiar (curva suave). u8 {h,w} 0|255.
  defp clean_smooth_mask(labels, id, w, min_area) do
    labels
    |> Nx.equal(id)
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
    |> drop_small_components(min_area)
    |> close_blur(w)
  end

  defp drop_small_components(mask_u8, min_area) do
    {_n, lbls, stats, _c} = Evision.connectedComponentsWithStats(Evision.Mat.from_nx(mask_u8))
    areas = Evision.Mat.to_nx(stats, Nx.BinaryBackend)[[.., 4]]

    keep =
      areas
      |> Nx.greater_equal(min_area)
      |> Nx.as_type(:u8)
      # rótulo 0 = fundo (área enorme): nunca acende
      |> Nx.put_slice([0], Nx.tensor([0], type: :u8))

    lbls_nx = lbls |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.as_type(:s64)
    keep |> Nx.take(lbls_nx) |> Nx.multiply(255) |> Nx.as_type(:u8)
  end

  defp close_blur(mask_u8, w) do
    mask_u8
    |> Evision.Mat.from_nx()
    |> Evision.morphologyEx(Evision.Constant.cv_MORPH_CLOSE(), kernel(5))
    |> Evision.gaussianBlur({0, 0}, max(w / 220.0, 1.5))
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.greater(127)
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
  end

  # gradiente morfológico (dilate − erode): anel fino na fronteira da máscara
  defp contour(mask_u8) do
    mat = Evision.Mat.from_nx(mask_u8)

    Evision.dilate(mat, kernel(3))
    |> Evision.subtract(Evision.erode(mat, kernel(3)))
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  defp kernel(s), do: Evision.getStructuringElement(Evision.Constant.cv_MORPH_ELLIPSE(), {s, s})

  # --- campo de cor (mescla por grupo) --------------------------------------

  # máscaras das partes presentes com a cor escolhida (uma varredura de labels)
  defp present_group_parts(labels, colors) do
    Layers.groups()
    |> Enum.map(fn g -> {Layers.mask(labels, g.ids), Map.get(colors, g.key, g.default)} end)
    |> Enum.filter(fn {mask, _c} -> Nx.to_number(Nx.sum(mask)) > 0 end)
  end

  # cada parte vira um peso SUAVE (borrado); nas interseções as cores se misturam
  # proporcionalmente (num/den) → fluidez de tubo de LED em vez de borda dura.
  defp blended_field(parts, w) do
    sigma = max(w / @field_blur_div, 3.0)
    {hh, ww} = parts |> hd() |> elem(0) |> Nx.shape()
    acc0 = {Nx.broadcast(0.0, {hh, ww, 3}), Nx.broadcast(0.0, {hh, ww})}

    {num, den} =
      Enum.reduce(parts, acc0, fn {mask, {r, g, b}}, {num, den} ->
        soft = mask |> to_unit_f32() |> blur2d(sigma)
        color = [r, g, b] |> Nx.tensor(type: :f32) |> Nx.reshape({1, 1, 3})
        {Nx.add(num, Nx.multiply(Nx.new_axis(soft, -1), color)), Nx.add(den, soft)}
      end)

    Nx.divide(num, Nx.new_axis(Nx.max(den, 1.0e-3), -1))
  end

  defp blur2d(t, sigma) do
    t
    |> Evision.Mat.from_nx()
    |> Evision.gaussianBlur({0, 0}, sigma)
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  defp to_unit_f32(u8), do: u8 |> Nx.as_type(:f32) |> Nx.divide(255.0)
end
