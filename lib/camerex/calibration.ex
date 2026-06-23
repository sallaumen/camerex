defmodule Camerex.Calibration do
  @moduledoc """
  Sessão de calibragem ao vivo: parseia a prévia **uma vez** (a parte cara
  do pipeline, ~300ms) e recompõe a cada ajuste de controle via
  `Photo.render_with_labels` (milissegundos). A prévia trabalha reduzida a
  #{480}px de largura — calibragem é sobre proporções de halo/detalhe/cor,
  não sobre resolução.
  """

  alias Camerex.{Mask, Parser}
  alias Camerex.Parser.{Hair, LayerRegistry, Layers}
  alias Camerex.Pipeline.{FramePreview, LayerRunner, Photo}

  @preview_width 480

  # `fg_cache` guarda as segmentações U²-Net que QUALQUER camada pode pedir
  # (`{model, kind} => tensor`), pré-computadas UMA vez na prepare. Como a UI
  # liga/desliga camadas ao vivo, o cache fica pronto pra qualquer combinação —
  # `render_neon` recompõe a cada ajuste SEM rodar o U²-Net de novo.
  @type session :: %{
          rgb: Nx.Tensor.t(),
          labels: Nx.Tensor.t() | nil,
          fg_cache: %{{String.t(), :largest | :full} => Nx.Tensor.t()}
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

  @doc "Reduz a imagem e roda as segmentações da sessão (1× por {model, kind})."
  @spec prepare(Nx.Tensor.t()) :: {:ok, session()} | {:error, term()}
  def prepare(rgb) do
    rgb = shrink(rgb)
    segmenter = Application.fetch_env!(:camerex, :segmenter)
    pairs = LayerRegistry.required_segmentations(LayerRegistry.all())

    with {:ok, fg_cache} <- segment_pairs(segmenter, rgb, pairs) do
      # parseia as partes (cor-por-parte é o ÚNICO modo); parser ausente → labels
      # nil e a prévia avisa que o parser está indisponível
      labels =
        case Parser.parse(rgb) do
          {:ok, l} -> l
          {:error, _} -> nil
        end

      {:ok, %{rgb: rgb, labels: labels, fg_cache: fg_cache}}
    end
  end

  # roda o segmenter 1× por {model, kind} e extrai o tensor (largest/full)
  defp segment_pairs(segmenter, rgb, pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {model, kind}, {:ok, acc} ->
      case segmenter.segment(rgb, model: model) do
        {:ok, raw} -> {:cont, {:ok, Map.put(acc, {model, kind}, extract_fg(raw, kind))}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp extract_fg(raw, :largest), do: Mask.largest_component(raw)
  defp extract_fg(raw, :full), do: raw |> Nx.greater(0) |> Nx.multiply(255) |> Nx.as_type(:u8)

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

  @doc """
  Detecção avançada: aprende um MODELO de cor do cabelo a partir de uma REGIÃO
  marcada na prévia (retângulo em frações `{x0, y0, x1, y1}`). O modelo capta as
  várias tonalidades (não 1 cor) e é invariante à posição — serve foto E vídeo.
  Devolve `%{mu: _, cov_inv: _}` ou `nil` (região sem textura). Ver
  `Hair.learn_model/2`.
  """
  @spec learn_hair_model(session(), {number(), number(), number(), number()}) ::
          %{mu: [float()], cov_inv: [float()]} | nil
  def learn_hair_model(%{rgb: rgb}, bbox), do: Hair.learn_model(rgb, bbox)

  # cor-por-parte (único modo): precisa dos rótulos do parser. As camadas ATIVAS
  # reusam o `fg_cache` da sessão via o `fg_provider` — render recompõe sem rodar
  # U²-Net por slider (mantém a prévia ao vivo em ms).
  defp render_neon(%{rgb: rgb, labels: labels, fg_cache: fg_cache}, params)
       when labels != nil do
    fg_provider = fn pair -> Map.get(fg_cache, pair) end
    labels = LayerRunner.run(labels, rgb, params, fg_provider: fg_provider, video?: false)

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
