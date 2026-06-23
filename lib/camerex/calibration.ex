defmodule Camerex.Calibration do
  @moduledoc """
  Sessão de calibragem ao vivo: parseia a prévia **uma vez** (a parte cara
  do pipeline, ~300ms) e recompõe a cada ajuste de controle via
  `Photo.render_with_labels` (milissegundos). A prévia trabalha reduzida a
  #{480}px de largura — calibragem é sobre proporções de halo/detalhe/cor,
  não sobre resolução.
  """

  alias Camerex.{Mask, Parser}
  alias Camerex.Parser.{Apparatus, Hair, Layers, Object}
  alias Camerex.Pipeline.{FramePreview, Photo}

  @preview_width 480

  # `mask` = maior componente (pessoa/objeto, do model da sessão); `fg_full` =
  # foreground COMPLETO do `u2netp` que o tecido aéreo precisa (pega o drapeado
  # que o u2net perde). Ambos guardados na prepare pra reusar sem rodar o U²-Net
  # a cada ajuste de controle (a prévia ao vivo bate com o render final).
  @type session :: %{
          rgb: Nx.Tensor.t(),
          mask: Nx.Tensor.t(),
          fg_full: Nx.Tensor.t(),
          labels: Nx.Tensor.t() | nil
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

  @doc "Reduz a imagem e roda a segmentação única da sessão."
  @spec prepare(Nx.Tensor.t(), String.t()) :: {:ok, session()} | {:error, term()}
  def prepare(rgb, model \\ "u2net") do
    rgb = shrink(rgb)
    segmenter = Application.fetch_env!(:camerex, :segmenter)

    with {:ok, raw} <- segmenter.segment(rgb, model: model),
         {:ok, aerial_raw} <- aerial_segment(segmenter, rgb, model, raw) do
      # parseia as partes (cor-por-parte é o ÚNICO modo); parser ausente → labels
      # nil e a prévia avisa que o parser está indisponível
      labels =
        case Parser.parse(rgb) do
          {:ok, l} -> l
          {:error, _} -> nil
        end

      fg_full = aerial_raw |> Nx.greater(0) |> Nx.multiply(255) |> Nx.as_type(:u8)
      {:ok, %{rgb: rgb, mask: Mask.largest_component(raw), fg_full: fg_full, labels: labels}}
    end
  end

  # fg do tecido aéreo via u2netp (reusa o raw da sessão se já for u2netp)
  defp aerial_segment(_segmenter, _rgb, "u2netp", raw), do: {:ok, raw}
  defp aerial_segment(segmenter, rgb, _model, _raw), do: segmenter.segment(rgb, model: "u2netp")

  @doc """
  Recompõe a prévia cor-por-parte com os params do painel (`%{"halo" => _,
  "detail" => _, "layer_colors" => _, …}`) e devolve um data URL PNG.
  """
  @spec render(session(), map()) :: {:ok, String.t()} | {:error, term()}
  def render(session, params) do
    with {:ok, neon} <- render_neon(session, params) do
      encode_data_url(neon)
    end
  end

  @doc """
  Eyedropper: amostra a cor do cabelo a partir de um clique na prévia (frações
  `{xf, yf}` em 0..1). Devolve `{r, g, b}` ou `nil` se o clique cair no vazio
  liso (a UI avisa "clique no cabelo"). Ver `Hair.sample_color/3`.
  """
  @spec sample_hair_color(session(), {number(), number()}) ::
          {0..255, 0..255, 0..255} | nil
  def sample_hair_color(%{rgb: rgb}, {xf, yf}), do: Hair.sample_color(rgb, {xf, yf})

  # cor-por-parte (único modo): precisa dos rótulos do parser
  defp render_neon(%{rgb: rgb, mask: mask, fg_full: fg_full, labels: labels}, params)
       when labels != nil do
    # objeto e tecido reusam o U²-Net que a sessão já tem (sem rodar de novo):
    # objeto via maior componente, tecido via foreground completo
    labels =
      labels
      |> maybe_object(params["detect_object"], mask)
      |> maybe_hair(
        params["detect_hair"],
        mask,
        rgb,
        params["hair_color"],
        params["hair_sensitivity"]
      )
      |> maybe_aerial(
        params["detect_aerial"],
        fg_full,
        rgb,
        params["aerial_color"],
        params["aerial_sensitivity"]
      )

    opts =
      [
        halo: params["halo"],
        bloom: params["bloom"] || 0.0,
        detail: params["detail"],
        layer_colors: Layers.normalize_colors(params["layer_colors"]),
        fill: params["fill"] || false,
        fill_color: params["fill_color"] || 0.45,
        fill_texture: params["fill_texture"] || 0.15
      ] ++ bg_opts(params) ++ floor_opts(params)

    {:ok, Photo.render_with_labels(rgb, labels, opts)}
  end

  defp render_neon(_session, _params), do: {:error, "parser de partes indisponível"}

  defp maybe_object(labels, true, mask),
    do: Object.into_labels(labels, Object.detect(mask, labels))

  defp maybe_object(labels, _off, _mask), do: labels

  # cabelo: FALLBACK por cor só quando o ATR não enxerga cabeça E há cor indicada.
  # Reusa o `mask` da sessão (maior componente do u2net = silhueta com o cabelo).
  defp maybe_hair(labels, true, mask, rgb, color, sens) when not is_nil(color) do
    if Hair.present?(labels) do
      labels
    else
      Hair.into_labels(labels, Hair.detect(mask, labels, rgb, color, sensitivity: sens || 0.5))
    end
  end

  defp maybe_hair(labels, _on, _mask, _rgb, _color, _sens), do: labels

  defp maybe_aerial(labels, true, fg_full, rgb, color, sens),
    do:
      Apparatus.into_labels(
        labels,
        Apparatus.detect(fg_full, labels, rgb, color, sensitivity: sens || 0.5)
      )

  defp maybe_aerial(labels, _off, _fg_full, _rgb, _color, _sens), do: labels

  defp bg_opts(params) do
    [
      bg_opacity: params["bg_opacity"] || 0.0,
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
