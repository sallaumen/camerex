defmodule Camerex.Calibration do
  @moduledoc """
  Sessão de calibragem ao vivo: segmenta a prévia **uma vez** (a parte cara
  do pipeline, ~300ms) e recompõe a cada ajuste de controle via
  `Photo.render_with_mask` (milissegundos). A prévia trabalha reduzida a
  #{480}px de largura — calibragem é sobre proporções de halo/detalhe/cor,
  não sobre resolução.
  """

  alias Camerex.{Mask, Parser}
  alias Camerex.Parser.{Layers, Object}
  alias Camerex.Pipeline.{FramePreview, Photo}

  @preview_width 480

  @type session :: %{rgb: Nx.Tensor.t(), mask: Nx.Tensor.t(), labels: Nx.Tensor.t() | nil}

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
      # parseia as partes uma vez também (modo "cor por camada"); se o parser
      # falhar (modelo ausente), labels = nil e o layered cai pro modo normal
      labels =
        case Parser.parse(rgb) do
          {:ok, l} -> l
          {:error, _} -> nil
        end

      {:ok, %{rgb: rgb, mask: Mask.largest_component(raw), labels: labels}}
    end
  end

  @doc """
  Recompõe a prévia com os params do painel
  (`%{"preset" => _, "halo" => _, "detail" => _, "swap_sides" => _}`)
  e devolve um data URL PNG pronto para `<img src>`.
  """
  @spec render(session(), map()) :: {:ok, String.t()} | {:error, term()}
  def render(session, params) do
    with {:ok, neon} <- render_neon(session, params) do
      encode_data_url(neon)
    end
  end

  # modo "cor por camada" (parser pronto na sessão) vs. modo normal (máscara)
  defp render_neon(%{rgb: rgb, mask: mask, labels: labels}, %{"layered" => true} = params)
       when labels != nil do
    # objeto reusa a máscara U²-Net que a sessão já tem (sem rodar de novo)
    labels =
      if params["detect_object"],
        do: Object.into_labels(labels, Object.detect(mask, labels)),
        else: labels

    opts =
      [
        halo: params["halo"],
        bloom: params["bloom"] || 0.0,
        detail: params["detail"],
        chroma: params["chroma"] || 0.5,
        layer_colors: Layers.normalize_colors(params["layer_colors"]),
        fill: params["fill"] || false,
        fill_color: params["fill_color"] || 0.45,
        fill_texture: params["fill_texture"] || 0.15
      ] ++ bg_opts(params) ++ floor_opts(params)

    {:ok, Photo.render_with_labels(rgb, labels, opts)}
  end

  defp render_neon(%{rgb: rgb, mask: mask}, params) do
    opts =
      [
        preset: params["preset"],
        halo: params["halo"],
        bloom: params["bloom"] || 0.0,
        detail: params["detail"],
        chroma: params["chroma"] || 0.0,
        swap_sides: params["swap_sides"] || false
      ] ++ bg_opts(params) ++ floor_opts(params)

    Photo.render_with_mask(rgb, mask, opts)
  end

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
