defmodule Camerex.Calibration do
  @moduledoc """
  Sessão de calibragem ao vivo: parseia a prévia **uma vez** e recompõe a cada
  ajuste de controle via `Photo.render_with_labels`. A prévia trabalha reduzida a
  #{480}px de largura — calibragem é sobre proporções de halo/detalhe/cor, não
  sobre resolução.

  Três artefatos caros são cacheados na sessão pra a prévia ficar ágil:

    * **`edges`** — as bordas posterizadas (mean-shift, depende SÓ do rgb).
      Computadas 1× no `prepare` e reusadas a cada slider (sem isto, todo ajuste
      re-rodava o mean-shift, ~2s).
    * **`fg_cache`** — as segmentações SOD que as camadas pedem, computadas
      PREGUIÇOSAMENTE (só quando a camada é ligada). Assim a sessão típica não
      paga o BiRefNet do `person_fill` (~5s) sem nunca ligá-lo.
    * **`head_cache`** — a máscara-cabeça do `HeadFusion` (7 inferências), que
      independe de slider: roda 1× quando ligado e é reaplicada a cada ajuste,
      em vez de re-inferir por slider (era ~15s/render).

  `render/2` devolve a sessão (possivelmente com caches novos) pra a LiveView
  guardar e o próximo render reusar.
  """

  alias Camerex.{Mask, Parser}
  alias Camerex.Neon.Layered
  alias Camerex.Parser.{Hair, HeadFusion, LayerContext, LayerRegistry, Layers}
  alias Camerex.Pipeline.{FramePreview, LayerRunner, Photo}

  @preview_width 480

  @type session :: %{
          rgb: Nx.Tensor.t(),
          labels: Nx.Tensor.t() | nil,
          edges: Nx.Tensor.t() | nil,
          fg_cache: %{{String.t(), :largest | :full} => Nx.Tensor.t()},
          head_cache: Nx.Tensor.t() | nil
        }

  @doc """
  Prepara a sessão direto de um arquivo de mídia: foto é lida inteira;
  vídeo usa o frame central (mesma fonte da prévia de 1 frame).
  """
  @spec prepare_file(Path.t(), String.t()) :: {:ok, session()} | {:error, term()}
  def prepare_file(path, "video") do
    with {:ok, rgb} <- FramePreview.middle_frame_rgb(path), do: prepare(rgb)
  end

  def prepare_file(path, _photo_type) do
    with {:ok, rgb} <- read_rgb(path), do: prepare(rgb)
  end

  @doc """
  Reduz a imagem, parseia as partes e pré-computa o mean-shift (caro, depende só
  do rgb). As segmentações SOD ficam preguiçosas (`fg_cache` vazio) — só rodam
  quando a camada que as pede é ligada.
  """
  @spec prepare(Nx.Tensor.t()) :: {:ok, session()}
  def prepare(rgb) do
    rgb = shrink(rgb)

    # parseia as partes (cor-por-parte é o ÚNICO modo); parser ausente → labels
    # nil e a prévia avisa que o parser está indisponível
    labels =
      case Parser.parse(rgb) do
        {:ok, l} -> l
        {:error, _} -> nil
      end

    edges = if labels, do: Layered.posterized_edges(rgb), else: nil

    {:ok, %{rgb: rgb, labels: labels, edges: edges, fg_cache: %{}, head_cache: nil}}
  end

  defp extract_fg(raw, :largest), do: Mask.largest_component(raw)
  defp extract_fg(raw, :full), do: raw |> Nx.greater(0) |> Nx.multiply(255) |> Nx.as_type(:u8)

  @doc """
  Recompõe a prévia cor-por-parte com os params do painel e devolve um data URL
  PNG **mais a sessão** (com os caches preguiçosos preenchidos no caminho).
  """
  @spec render(session(), map()) :: {:ok, String.t(), session()} | {:error, term()}
  def render(session, params) do
    session = ensure_caches(session, params)

    with {:ok, neon} <- render_neon(session, params),
         {:ok, url} <- encode_data_url(neon) do
      {:ok, url, session}
    end
  end

  # preenche preguiçosamente o que as camadas ATIVAS pedem e ainda falta no cache:
  # as segmentações SOD (fg) e a máscara-cabeça do head_fusion.
  defp ensure_caches(%{labels: nil} = session, _params), do: session

  defp ensure_caches(session, params) do
    active = LayerRegistry.active(params)
    session |> ensure_fg(active) |> ensure_head(params)
  end

  # roda o segmenter SÓ pelos {model, kind} que as camadas ativas exigem e ainda
  # não estão no cache (ex.: BiRefNet do person_fill só quando ele é ligado).
  defp ensure_fg(%{rgb: rgb, fg_cache: cache} = session, active) do
    segmenter = Application.fetch_env!(:camerex, :segmenter)

    filled =
      active
      |> LayerRegistry.required_segmentations()
      |> Enum.reject(&Map.has_key?(cache, &1))
      |> Enum.reduce(cache, fn {model, kind} = pair, acc ->
        case segmenter.segment(rgb, model: model) do
          {:ok, raw} -> Map.put(acc, pair, extract_fg(raw, kind))
          {:error, _} -> acc
        end
      end)

    %{session | fg_cache: filled}
  end

  # head_fusion independe de slider (só do rgb): roda as 7 inferências 1× e cacheia
  # a máscara-cabeça; render_neon a reaplica a cada ajuste.
  defp ensure_head(
         %{head_cache: nil, rgb: rgb, labels: labels, fg_cache: cache} = session,
         params
       ) do
    if params["detect_head_fusion"] == true do
      ctx = %LayerContext{
        rgb: rgb,
        labels: labels,
        fg: Map.get(cache, {"u2netp", :full}),
        video?: false
      }

      %{session | head_cache: HeadFusion.run(ctx)}
    else
      session
    end
  end

  defp ensure_head(session, _params), do: session

  @doc """
  Eyedropper genérico: amostra a cor de um param `:color` a partir de um clique na
  prévia (frações `{xf, yf}` em 0..1). `:hair_color` usa o amostrador texturizado do
  cabelo (devolve `nil` no vazio liso — a UI avisa); os demais params de cor (ex.:
  `:aerial_color`) usam a média da janela (cor sólida, sempre devolve `{r,g,b}`).
  Ver `Hair.sample_color/3`.
  """
  @spec sample_color(session(), atom(), {number(), number()}) ::
          {0..255, 0..255, 0..255} | nil
  def sample_color(%{rgb: rgb}, :hair_color, point), do: Hair.sample_color(rgb, point)
  def sample_color(%{rgb: rgb}, _color_key, point), do: avg_point(rgb, point)

  # média de RGB numa janela ao redor do ponto (frações 0..1), sem o gate de textura
  # do cabelo — serve cores sólidas (tecido). Sempre devolve {r,g,b}.
  defp avg_point(rgb, {xf, yf}) do
    {h, w, _} = Nx.shape(rgb)
    r = max(round(w / 40), 2)
    cx = round(clamp01(xf) * (w - 1))
    cy = round(clamp01(yf) * (h - 1))
    {x0, y0} = {max(cx - r, 0), max(cy - r, 0)}
    {x1, y1} = {min(cx + r, w - 1), min(cy + r, h - 1)}

    [rr, gg, bb] =
      rgb[[y0..y1, x0..x1, 0..2]]
      |> Nx.as_type(:f32)
      |> Nx.mean(axes: [0, 1])
      |> Nx.round()
      |> Nx.as_type(:s32)
      |> Nx.to_flat_list()

    {rr, gg, bb}
  end

  defp clamp01(s), do: s |> max(0.0) |> min(1.0)

  @doc """
  Detecção avançada: aprende um MODELO de cor do cabelo a partir de uma REGIÃO
  marcada na prévia (retângulo em frações `{x0, y0, x1, y1}`). O modelo capta as
  várias tonalidades (não 1 cor) e é invariante à posição — serve foto E vídeo.
  Devolve `%{mu: _, cov_inv: _}` ou `nil` (região sem textura). Ver
  `Hair.learn_model/2`.
  """
  # devolve o modelo (mu/cov_inv do Lab + prior espacial cx/cy/sigma) ou nil — map()
  # aberto porque o merge com o prior soma chaves além de mu/cov_inv
  @spec learn_hair_model(session(), {number(), number(), number(), number()}) :: map() | nil
  def learn_hair_model(%{rgb: rgb}, bbox), do: Hair.learn_model(rgb, bbox)

  # cor-por-parte (único modo): precisa dos rótulos do parser. As camadas ATIVAS
  # reusam o `fg_cache` da sessão; o head_fusion (cacheado) é APLICADO aqui e tirado
  # dos params, pra o LayerRunner não re-rodar as 7 inferências por slider. As bordas
  # posterizadas (mean-shift) vêm prontas da sessão.
  defp render_neon(
         %{rgb: rgb, labels: labels, fg_cache: fg_cache, edges: edges, head_cache: head},
         params
       )
       when labels != nil do
    {base, params} = apply_head_cache(labels, head, params)
    fg_provider = fn pair -> Map.get(fg_cache, pair) end
    labels = LayerRunner.run(base, rgb, params, fg_provider: fg_provider, video?: false)

    opts =
      [
        halo: params["halo"],
        bloom: params["bloom"] || 0.0,
        detail: params["detail"],
        layer_colors: Layers.normalize_colors(params["layer_colors"]),
        fill: params["fill"] || false,
        fill_color: params["fill_color"] || 0.45,
        fill_texture: params["fill_texture"] || 0.15,
        edges: edges
      ] ++ bg_opts(params) ++ floor_opts(params)

    {:ok, Photo.render_with_labels(rgb, labels, opts)}
  end

  defp render_neon(_session, _params), do: {:error, "parser de partes indisponível"}

  # aplica a máscara-cabeça cacheada e desliga a flag (head_fusion já injetado);
  # sem cache (camada off ou ainda não computada) deixa os params intactos.
  defp apply_head_cache(labels, head, params) do
    if params["detect_head_fusion"] == true and head != nil do
      {HeadFusion.into_labels(labels, head), Map.put(params, "detect_head_fusion", false)}
    else
      {labels, params}
    end
  end

  defp bg_opts(params) do
    [
      bg_opacity: params["bg_opacity"] || 0.0,
      bg_blur: params["bg_blur"] || 0.0,
      transparent_bg: params["transparent_bg"] || false
    ]
  end

  defp floor_opts(params) do
    [
      floor: params["floor"] || false,
      glow: params["glow"] || 0.85,
      spread: params["spread"] || 0.5
    ]
  end

  # INTER_AREA no downscale: única interpolação do OpenCV com anti-alias
  # (ver scripts/spikes/RESULTS.md — a lição da paridade golden)
  defp shrink(rgb) do
    {h, w, 3} = Nx.shape(rgb)

    if w <= @preview_width do
      rgb
    else
      new_h = round(h * @preview_width / w)

      rgb
      |> Evision.Mat.from_nx_2d()
      |> Evision.resize({@preview_width, new_h},
        interpolation: Evision.Constant.cv_INTER_AREA()
      )
      |> Evision.Mat.to_nx(Nx.BinaryBackend)
    end
  end

  defp read_rgb(path) do
    case Evision.imread(path) do
      %Evision.Mat{} = bgr ->
        {:ok,
         bgr
         |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
         |> Evision.Mat.to_nx(Nx.BinaryBackend)}

      _other ->
        {:error, "não consegui ler #{Path.basename(path)}"}
    end
  end

  # RGBA (fundo transparente) vira PNG com alpha; RGB vira PNG normal — o
  # <img> da prévia mostra a transparência sobre o fundo do painel
  defp encode_data_url(tensor) do
    mat = Evision.Mat.from_nx_2d(tensor)

    out =
      case Nx.shape(tensor) do
        {_h, _w, 4} -> Evision.cvtColor(mat, Evision.Constant.cv_COLOR_RGBA2BGRA())
        _ -> Evision.cvtColor(mat, Evision.Constant.cv_COLOR_RGB2BGR())
      end

    case Evision.imencode(".png", out) do
      bin when is_binary(bin) -> {:ok, "data:image/png;base64," <> Base.encode64(bin)}
      other -> {:error, other}
    end
  end
end
