defmodule Camerex.Pipeline.Photo do
  @moduledoc """
  Pipeline de foto (contrato §4): segmentar → maior componente → bordas →
  compor. Puro exceto a chamada ao segmenter configurado em
  `config :camerex, :segmenter`. `run/2` (item do Workspace, neon.png,
  thumbs, manifest) chega na Fase 3.
  """

  alias Camerex.{Mask, Neon, Parser, Workspace}
  alias Camerex.Neon.{Background, Layered, Scene}
  alias Camerex.Parser.{Apparatus, Layers, Object}

  @doc """
  Render por camada semântica (ÚNICO modo): parseia as partes
  (cabelo/pele/roupa/…) e pinta cada uma com sua cor, compondo por máximo.
  """
  @spec render_layered(Nx.Tensor.t(), keyword()) :: {:ok, Nx.Tensor.t()} | {:error, term()}
  def render_layered(rgb, opts \\ []) do
    with {:ok, labels} <- Parser.parse(rgb) do
      {:ok, render_with_labels(rgb, augment_labels(rgb, labels, opts), opts)}
    end
  end

  # opt-in: injeta as classes virtuais — objeto na mão (18, maior componente do
  # U²-Net) e/ou tecido aéreo (19, foreground COMPLETO − pessoa). Cada um roda seu
  # modelo: objeto no `u2net`, tecido no `u2netp` (pega o drapeado/fitas que o
  # u2net perde sob luz colorida). Ver Parser.Object / Parser.Apparatus.
  defp augment_labels(rgb, labels, opts) do
    labels
    |> with_object(rgb, Keyword.get(opts, :detect_object, false))
    |> with_aerial(
      rgb,
      Keyword.get(opts, :aerial_color),
      Keyword.get(opts, :aerial_sensitivity, 0.5),
      Keyword.get(opts, :detect_aerial, false)
    )
  end

  defp with_object(labels, _rgb, false), do: labels

  defp with_object(labels, rgb, true) do
    case segment(rgb, "u2net") do
      {:ok, raw} -> Object.into_labels(labels, Object.detect(Mask.largest_component(raw), labels))
      :error -> labels
    end
  end

  # tecido usa o foreground COMPLETO (todos os componentes), não o maior — tecido
  # e pessoa são componentes separados (ver Parser.Apparatus). A cor do tecido
  # (aerial_color) enriquece a saliência.
  defp with_aerial(labels, _rgb, _color, _sens, false), do: labels

  defp with_aerial(labels, rgb, color, sens, true) do
    case segment(rgb, "u2netp") do
      {:ok, raw} ->
        mask = Apparatus.detect(full_foreground(raw), labels, rgb, color, sensitivity: sens)
        Apparatus.into_labels(labels, mask)

      :error ->
        labels
    end
  end

  defp segment(rgb, model) do
    segmenter = Application.fetch_env!(:camerex, :segmenter)

    case segmenter.segment(rgb, model: model) do
      {:ok, raw} -> {:ok, raw}
      _ -> :error
    end
  end

  defp full_foreground(raw), do: raw |> Nx.greater(0) |> Nx.multiply(255) |> Nx.as_type(:u8)

  @doc """
  Parte pós-parse do render por camada (a calibragem parseia 1x e chama isto).
  A arte-de-linha e o campo de cor vêm do `Neon.Layered` (regra compartilhada
  com o vídeo): contornos das máscaras semânticas suaves — sem o Canva da foto,
  logo sem o chuvisco/"quadrados" da textura do tecido.
  """
  @spec render_with_labels(Nx.Tensor.t(), Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  def render_with_labels(rgb, labels, opts \\ []) do
    halo = Keyword.get(opts, :halo, 0.6)
    bloom = Keyword.get(opts, :bloom, 0.0)
    detail = Keyword.get(opts, :detail, 0.5)
    colors = Keyword.get(opts, :layer_colors, Layers.default_colors())
    {_h, w, _} = Nx.shape(rgb)

    line = Layered.line_art(rgb, labels, detail: detail)
    field = Layered.color_field(labels, colors, w)

    Neon.compose(line, halo: halo, bloom: bloom, color_field: field)
    |> with_fill(rgb, field, labels, opts)
    |> Background.behind(rgb, Keyword.get(opts, :bg_opacity, 0.0) || 0.0)
    |> with_floor(opts)
    |> Background.cutout(Keyword.get(opts, :transparent_bg, false))
  end

  # preenchimento texturizado SOB as linhas (opt-in): a cor de cada parte com
  # opacidade própria + a luminância da foto (textura) com opacidade própria,
  # confinado à figura. Por máximo, então as linhas ficam crispas por cima.
  defp with_fill(neon, rgb, field, labels, opts) do
    if Keyword.get(opts, :fill, false) do
      fill =
        Layered.texture_fill(rgb, field, labels,
          color: Keyword.get(opts, :fill_color, 0.45),
          texture: Keyword.get(opts, :fill_texture, 0.15)
        )

      neon |> Nx.as_type(:f32) |> Nx.max(fill) |> Nx.clip(0, 255) |> Nx.as_type(:u8)
    else
      neon
    end
  end

  # anexa o chão (Neon.Scene) quando ligado; opt-in, default neutro
  defp with_floor(neon, opts) do
    if Keyword.get(opts, :floor, false) do
      Scene.apply(neon,
        glow: Keyword.get(opts, :glow, 0.85),
        spread: Keyword.get(opts, :spread, 0.5)
      )
    else
      neon
    end
  end

  @spec run(String.t(), (non_neg_integer(), non_neg_integer() -> any()) | nil) ::
          :ok | {:error, term()}
  def run(item_id, progress_cb) do
    started_ms = System.monotonic_time(:millisecond)

    try do
      {:ok, manifest} = Workspace.manifest(item_id)
      rgb = read_rgb!(Workspace.item_path(item_id, manifest["original_file"]))
      {h, w, 3} = Nx.shape(rgb)

      neon =
        case render_layered(rgb, render_opts(manifest)) do
          {:ok, tensor} -> tensor
          {:error, reason} -> raise "pipeline de foto falhou: #{inspect(reason)}"
        end

      write_png!(Workspace.item_path(item_id, "neon.png"), neon)
      :ok = Workspace.write_thumbs(item_id)

      total_ms = System.monotonic_time(:millisecond) - started_ms

      {:ok, _} =
        Workspace.update_manifest(item_id, fn m ->
          m
          |> Map.put("status", "done")
          |> Map.put("output_file", "neon.png")
          |> Map.put("error", nil)
          |> Map.put("media", %{"width" => w, "height" => h})
          |> Map.put("completed_at", DateTime.to_iso8601(DateTime.now!("America/Sao_Paulo")))
          |> Map.put("timings_ms", %{"total" => total_ms, "per_frame_avg" => total_ms})
        end)

      if progress_cb, do: progress_cb.(1, 1)
      :ok
    rescue
      e ->
        # grava o erro legível e re-levanta: o Jobs vê o DOWN anormal da Task
        _ =
          Workspace.update_manifest(item_id, fn m ->
            m |> Map.put("status", "failed") |> Map.put("error", Exception.message(e))
          end)

        reraise e, __STACKTRACE__
    end
  end

  # passa só o que o manifest tem; cada consumidor (render_with_labels,
  # with_floor, …) aplica seu default via Keyword.get, então descartamos os
  # ausentes para o fallback funcionar (e o credo não reclamar de complexidade)
  defp render_opts(manifest) do
    p = manifest["params"] || %{}

    [
      halo: p["halo"],
      bloom: p["bloom"],
      detail: p["detail"],
      layer_colors: Layers.normalize_colors(p["layer_colors"]),
      detect_object: p["detect_object"],
      detect_aerial: p["detect_aerial"],
      aerial_color: p["aerial_color"],
      aerial_sensitivity: p["aerial_sensitivity"],
      bg_opacity: p["bg_opacity"],
      transparent_bg: p["transparent_bg"],
      fill: p["fill"],
      fill_color: p["fill_color"],
      fill_texture: p["fill_texture"],
      floor: p["floor"],
      glow: p["glow"],
      spread: p["spread"]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  # Evision.imread devolve BGR; o domínio inteiro é RGB (contrato §4),
  # então a conversão acontece aqui, na borda.
  defp read_rgb!(path) do
    case Evision.imread(path) do
      %Evision.Mat{} = bgr ->
        if match?({h, w, _c} when h > 0 and w > 0, Evision.Mat.shape(bgr)) do
          bgr
          |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
          |> Evision.Mat.to_nx(Nx.BinaryBackend)
        else
          raise "imagem original vazia ou corrompida: #{Path.basename(path)}"
        end

      _other ->
        raise "não consegui ler a imagem original: #{Path.basename(path)}"
    end
  end

  # RGBA (fundo transparente) grava PNG com alpha; RGB grava normal
  defp write_png!(path, tensor) do
    out = to_bgr_mat(tensor)

    case Evision.imwrite(path, out) do
      true -> :ok
      other -> raise "falha ao gravar #{Path.basename(path)}: #{inspect(other)}"
    end
  end

  defp to_bgr_mat(tensor) do
    mat = Evision.Mat.from_nx_2d(tensor)

    case Nx.shape(tensor) do
      {_h, _w, 4} -> Evision.cvtColor(mat, Evision.Constant.cv_COLOR_RGBA2BGRA())
      _ -> Evision.cvtColor(mat, Evision.Constant.cv_COLOR_RGB2BGR())
    end
  end
end
