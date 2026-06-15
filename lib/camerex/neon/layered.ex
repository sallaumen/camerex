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

  alias Camerex.Neon
  alias Camerex.Neon.Palette
  alias Camerex.Parser.Layers

  # componentes de um rótulo menores que esta fração da imagem são ilhas de
  # rotulagem espúria (um patch de "pele" no meio da roupa) — descartadas antes
  # de virar contorno, senão pingam bolhinhas soltas na arte.
  @island_area_frac 0.0004

  # contornos: loops ISOLADOS menores que esta fração viram "bolinhas" (anel de
  # uma ilha que sobrou). A silhueta e as fronteiras reais são um componente
  # enorme conectado, então só os ovais soltos caem.
  @contour_min_area_frac 0.0005

  # detalhe interno: o slider [0,1] vira o `detail` do trace_edges. A banda vai
  # quase até o nível do mono (gradiente forte = rosto, vincos, mãos; a textura
  # fraca do tecido fica de fora). chroma pega borda de COR também. Depois a
  # supressão por densidade tira só a textura MUITO densa (renda, paetê) sem
  # tocar nas linhas esparsas do rosto/vincos.
  @detail_trace_scale 0.6
  @detail_chroma 0.3
  @density_sigma_div 120.0
  @density_threshold 0.4

  @doc """
  Arte-de-linha `{h, w}` f32 em [0, 1]: combina por máximo duas camadas —

    * **contornos semânticos** (sempre): silhueta + fronteiras entre partes, das
      máscaras suaves. Espinha dorsal limpa, zero textura.
    * **detalhe interno** (opt-in via `detail:` > 0): rosto, mãos, vincos do
      Canny, mas só onde o gradiente é forte (limiar alto) e com a textura densa
      suprimida — traz definição sem os "quadrados" do tecido.

  opts: `detail:` 0..1 (quanto detalhe interno; 0 = só contornos, default 0.5).
  """
  @spec line_art(Nx.Tensor.t(), Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  def line_art(rgb, labels, opts \\ []) do
    detail = Keyword.get(opts, :detail, 0.5)
    {_h, w, _} = Nx.shape(rgb)

    labels
    |> semantic_contours(w)
    |> Nx.max(internal_detail(rgb, labels, detail))
    |> to_unit_f32()
  end

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

  # detalhe interno (u8 {h,w}): Canny de limiar alto confinado à figura, com a
  # textura densa suprimida. detail <= 0 → sem detalhe (só contornos).
  defp internal_detail(rgb, labels, detail) do
    {h, w, _} = Nx.shape(rgb)

    if detail <= 0.0 do
      Nx.broadcast(Nx.u8(0), {h, w})
    else
      union = labels |> Nx.greater(0) |> Nx.multiply(255) |> Nx.as_type(:u8)

      rgb
      |> Neon.trace_edges(union, detail: detail * @detail_trace_scale, chroma: @detail_chroma)
      |> suppress_dense(w)
    end
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
  @spec color_field(Nx.Tensor.t(), %{atom() => Palette.color()}, pos_integer()) :: Nx.Tensor.t()
  def color_field(labels, colors, w) do
    {h, _w} = Nx.shape(labels)

    case present_group_parts(labels, colors) do
      [] -> Nx.broadcast(0.0, {h, w, 3})
      parts -> blended_field(parts, w)
    end
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
    sigma = max(w / 80.0, 4.0)
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
