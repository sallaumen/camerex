defmodule Camerex.Calibration do
  @moduledoc """
  Sessão de calibragem ao vivo: segmenta a prévia **uma vez** (a parte cara
  do pipeline, ~300ms) e recompõe a cada ajuste de controle via
  `Photo.render_with_mask` (milissegundos). A prévia trabalha reduzida a
  #{480}px de largura — calibragem é sobre proporções de halo/detalhe/cor,
  não sobre resolução.
  """

  alias Camerex.Mask
  alias Camerex.Pipeline.{FramePreview, Photo}

  @preview_width 480

  @type session :: %{rgb: Nx.Tensor.t(), mask: Nx.Tensor.t()}

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
      {:ok, %{rgb: rgb, mask: Mask.largest_component(raw)}}
    end
  end

  @doc """
  Recompõe a prévia com os params do painel
  (`%{"preset" => _, "halo" => _, "detail" => _, "swap_sides" => _}`)
  e devolve um data URL PNG pronto para `<img src>`.
  """
  @spec render(session(), map()) :: {:ok, String.t()} | {:error, term()}
  def render(%{rgb: rgb, mask: mask}, params) do
    opts = [
      preset: params["preset"],
      halo: params["halo"],
      bloom: params["bloom"] || 0.0,
      detail: params["detail"],
      chroma: params["chroma"] || 0.0,
      swap_sides: params["swap_sides"] || false
    ]

    with {:ok, neon} <- Photo.render_with_mask(rgb, mask, opts) do
      encode_data_url(neon)
    end
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

  defp encode_data_url(rgb_tensor) do
    bgr =
      Evision.cvtColor(Evision.Mat.from_nx_2d(rgb_tensor), Evision.Constant.cv_COLOR_RGB2BGR())

    case Evision.imencode(".png", bgr) do
      bin when is_binary(bin) -> {:ok, "data:image/png;base64," <> Base.encode64(bin)}
      other -> {:error, other}
    end
  end
end
