defmodule Camerex.Pipeline.Photo do
  @moduledoc """
  Pipeline de foto (contrato §4): segmentar → maior componente → bordas →
  compor. Puro exceto a chamada ao segmenter configurado em
  `config :camerex, :segmenter`. `run/2` (item do Workspace, neon.png,
  thumbs, manifest) chega na Fase 3.
  """

  alias Camerex.{Mask, Neon, Parser, Workspace}
  alias Camerex.Neon.Palette
  alias Camerex.Parser.Layers

  @spec render(Nx.Tensor.t(), keyword()) :: {:ok, Nx.Tensor.t()} | {:error, term()}
  def render(rgb, opts \\ []) do
    model = Keyword.get(opts, :model, "u2net")
    segmenter = Application.fetch_env!(:camerex, :segmenter)

    with {:ok, raw_mask} <- segmenter.segment(rgb, model: model) do
      render_with_mask(rgb, Mask.largest_component(raw_mask), opts)
    end
  end

  @doc """
  Composição pós-máscara (bordas + halos + cor): a parte barata do pipeline.
  A calibragem ao vivo segmenta uma vez e chama isto a cada ajuste.
  """
  @spec render_with_mask(Nx.Tensor.t(), Nx.Tensor.t(), keyword()) ::
          {:ok, Nx.Tensor.t()} | {:error, term()}
  def render_with_mask(rgb, mask, opts \\ []) do
    preset_id = Keyword.get(opts, :preset, "forro-teal")
    halo = Keyword.get(opts, :halo, 0.6)
    bloom = Keyword.get(opts, :bloom, 0.0)
    detail = Keyword.get(opts, :detail, 0.5)
    chroma = Keyword.get(opts, :chroma, 0.0)
    swap_sides = Keyword.get(opts, :swap_sides, false)

    with {:ok, preset} <- fetch_preset(preset_id) do
      edges =
        rgb
        |> Neon.trace_edges(mask, detail: detail, chroma: chroma)
        |> Nx.as_type(:f32)
        |> Nx.divide(255.0)

      {:ok,
       Neon.compose(edges, colors(preset, swap_sides), compose_opts(preset, mask, halo, bloom))}
    end
  end

  @doc """
  Render por camada semântica: parseia as partes (cabelo/pele/roupa/…) e
  pinta cada uma com sua cor, compondo por máximo. Cada camada herda o
  `chroma` para recuperar tecido de baixo contraste.
  """
  @spec render_layered(Nx.Tensor.t(), keyword()) :: {:ok, Nx.Tensor.t()} | {:error, term()}
  def render_layered(rgb, opts \\ []) do
    with {:ok, labels} <- Parser.parse(rgb) do
      {:ok, render_with_labels(rgb, labels, opts)}
    end
  end

  @doc "Parte pós-parse do render por camada (a calibragem parseia 1x e chama isto)."
  @spec render_with_labels(Nx.Tensor.t(), Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  def render_with_labels(rgb, labels, opts \\ []) do
    halo = Keyword.get(opts, :halo, 0.6)
    bloom = Keyword.get(opts, :bloom, 0.0)
    detail = Keyword.get(opts, :detail, 0.5)
    chroma = Keyword.get(opts, :chroma, 0.5)
    colors = Keyword.get(opts, :layer_colors, Layers.default_colors())

    {h, w, _} = Nx.shape(rgb)
    blank = Nx.broadcast(Nx.u8(0), {h, w, 3})

    Enum.reduce(Layers.groups(), blank, fn group, acc ->
      mask = Layers.mask(labels, group.ids)

      if Nx.to_number(Nx.sum(mask)) > 0 do
        color = Map.get(colors, group.key, group.default)

        edges =
          rgb
          |> Neon.trace_edges(mask, detail: detail, chroma: chroma)
          |> Nx.as_type(:f32)
          |> Nx.divide(255.0)

        Nx.max(acc, Neon.compose(edges, [color], halo: halo, bloom: bloom))
      else
        acc
      end
    end)
  end

  @spec run(String.t(), (non_neg_integer(), non_neg_integer() -> any()) | nil) ::
          :ok | {:error, term()}
  def run(item_id, progress_cb) do
    started_ms = System.monotonic_time(:millisecond)

    try do
      {:ok, manifest} = Workspace.manifest(item_id)
      rgb = read_rgb!(Workspace.item_path(item_id, manifest["original_file"]))
      {h, w, 3} = Nx.shape(rgb)

      opts = render_opts(manifest)
      renderer = if opts[:layered], do: &render_layered/2, else: &render/2

      neon =
        case renderer.(rgb, opts) do
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

  defp render_opts(manifest) do
    p = manifest["params"] || %{}

    [
      preset: manifest["preset"],
      halo: p["halo"] || 0.6,
      bloom: p["bloom"] || 0.0,
      detail: p["detail"] || 0.5,
      chroma: p["chroma"] || 0.0,
      swap_sides: p["swap_sides"] || false,
      model: p["model"] || "u2net",
      layered: p["layered"] || false,
      layer_colors: Layers.normalize_colors(p["layer_colors"])
    ]
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

  defp write_png!(path, rgb_tensor) do
    bgr =
      Evision.cvtColor(Evision.Mat.from_nx_2d(rgb_tensor), Evision.Constant.cv_COLOR_RGB2BGR())

    case Evision.imwrite(path, bgr) do
      true -> :ok
      other -> raise "falha ao gravar #{Path.basename(path)}: #{inspect(other)}"
    end
  end

  defp fetch_preset(id) do
    case Palette.get(id) do
      nil -> {:error, {:unknown_preset, id}}
      preset -> {:ok, preset}
    end
  end

  # swap_sides só faz sentido com 2 cores; em mono é ignorado
  defp colors(%{colors: [left, right]}, true), do: [right, left]
  defp colors(%{colors: colors}, _swap), do: colors

  defp compose_opts(%{mode: :gradient}, mask, halo, bloom) do
    {h, w} = Nx.shape(mask)
    {y_top, y_bottom} = Neon.mask_y_bounds(mask)
    weights = Neon.vertical_weights(h, w, y_top, y_bottom)
    [halo: halo, bloom: bloom, duotone_weights: weights]
  end

  defp compose_opts(%{mode: :duotone}, mask, halo, bloom) do
    {h, w} = Nx.shape(mask)
    weights = Neon.duotone_weights(h, w, Neon.mask_median_x(mask), 24)
    [halo: halo, bloom: bloom, duotone_weights: weights]
  end

  defp compose_opts(%{mode: :mono}, _mask, halo, bloom), do: [halo: halo, bloom: bloom]
end
