defmodule Camerex.Calibration do
  @moduledoc """
  Sessão de calibragem ao vivo: parseia a prévia **uma vez** (a parte cara
  do pipeline, ~300ms) e recompõe a cada ajuste de controle via
  `Photo.render_with_labels` (milissegundos). A prévia trabalha reduzida a
  #{480}px de largura — calibragem é sobre proporções de halo/detalhe/cor,
  não sobre resolução.
  """

  alias Camerex.{Mask, Parser}
  alias Camerex.Parser.{Apparatus, Layers, Object}
  alias Camerex.Pipeline.{FramePreview, Photo}

  @preview_width 480

  # `mask` = maior componente (objeto na mão); `fg_full` = foreground COMPLETO
  # (todos os componentes) que o tecido aéreo precisa — guardados na prepare pra
  # o aéreo/objeto reusarem sem rodar o U²-Net a cada ajuste de controle.
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

    with {:ok, raw} <- segmenter.segment(rgb, model: model) do
      # parseia as partes (cor-por-parte é o ÚNICO modo); parser ausente → labels
      # nil e a prévia avisa que o parser está indisponível
      labels =
        case Parser.parse(rgb) do
          {:ok, l} -> l
          {:error, _} -> nil
        end

      fg_full = raw |> Nx.greater(0) |> Nx.multiply(255) |> Nx.as_type(:u8)
      {:ok, %{rgb: rgb, mask: Mask.largest_component(raw), fg_full: fg_full, labels: labels}}
    end
  end

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

  # cor-por-parte (único modo): precisa dos rótulos do parser
  defp render_neon(%{rgb: rgb, mask: mask, fg_full: fg_full, labels: labels}, params)
       when labels != nil do
    # objeto e tecido reusam o U²-Net que a sessão já tem (sem rodar de novo):
    # objeto via maior componente, tecido via foreground completo
    labels =
      labels
      |> maybe_object(params["detect_object"], mask)
      |> maybe_aerial(params["detect_aerial"], fg_full, rgb, params["aerial_color"])

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

  defp maybe_aerial(labels, true, fg_full, rgb, color),
    do: Apparatus.into_labels(labels, Apparatus.detect(fg_full, labels, rgb, color))

  defp maybe_aerial(labels, _off, _fg_full, _rgb, _color), do: labels

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
