defmodule Camerex.Pipeline.Video do
  @moduledoc """
  Pipeline de vídeo neon: probe → decode → por frame (segmentação com
  componente consistente, EMA anti-flicker, rastro de luz, duotone com
  split estabilizado) → encode H.264. O estado temporal atravessa os
  frames num reduce; o stream do decoder mantém memória O(1 frame).
  """

  alias Camerex.{Mask, Neon, Workspace}
  alias Camerex.Neon.Palette
  alias Camerex.Video.{Decoder, Encoder, Probe}

  @work_width 640
  # cadência "shot on twos" da animação à mão: até 12 desenhos/s, cada um
  # segurado por 2 frames no container (playback = 2 × desenhos)
  @drawing_fps 12.0
  @mask_ema_alpha 0.45
  @mask_bin_threshold 0.45
  @split_ema_prev 0.9
  @split_ema_curr 0.1
  @dark_luma_threshold 70
  @duotone_blend_px 24
  @output_file "neon.mp4"

  @spec run(String.t(), (non_neg_integer(), non_neg_integer() -> any())) ::
          :ok | {:error, term()}
  def run(item_id, progress_cb) do
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, manifest} <- Workspace.manifest(item_id) do
        in_path = Workspace.item_path(item_id, manifest["original_file"])
        out_path = Workspace.item_path(item_id, @output_file)
        do_render(in_path, out_path, build_opts(manifest), progress_cb)
      end

    case result do
      {:ok, stats} ->
        write_video_thumbs(item_id, stats.first)
        total_ms = System.monotonic_time(:millisecond) - started

        {:ok, _} =
          Workspace.update_manifest(item_id, fn m ->
            Map.merge(m, %{
              "status" => "done",
              "output_file" => @output_file,
              "completed_at" => DateTime.to_iso8601(DateTime.now!("America/Sao_Paulo")),
              "media" => %{
                "width" => @work_width,
                "height" => stats.height,
                "frames" => stats.count,
                "fps" => stats.fps,
                "duration_s" => stats.count / stats.fps
              },
              "timings_ms" => %{
                "total" => total_ms,
                "per_frame_avg" => Float.round(total_ms / stats.count, 1)
              }
            })
          end)

        :ok

      {:error, reason} ->
        Workspace.update_manifest(item_id, fn m ->
          Map.merge(m, %{"status" => "failed", "error" => error_message(reason)})
        end)

        {:error, reason}
    end
  end

  @doc """
  Converte um arquivo de vídeo direto em disco, sem Workspace — usada por
  `run/2` (via `do_render`) e pela CLI `mix camerex.video`.

  opts (defaults do contrato): `preset:` (id da Palette, default "forro-teal"),
  `halo:` 0.6, `detail:` 0.5, `trail:` 0.7, `swap_sides:` false,
  `model:` "u2netp".
  """
  @spec render_file(
          Path.t(),
          Path.t(),
          keyword(),
          (non_neg_integer(), non_neg_integer() -> any())
        ) :: :ok | {:error, term()}
  def render_file(in_path, out_path, opts, progress_cb) do
    case do_render(in_path, out_path, build_opts_kw(opts), progress_cb) do
      {:ok, _stats} -> :ok
      {:error, _} = err -> err
    end
  end

  # miolo compartilhado: probe → decode → loop por frame → encode.
  # Devolve stats para o run/2 preencher manifest e thumbs.
  defp do_render(in_path, out_path, opts, progress_cb) do
    with {:ok, info} <- Probe.probe(in_path),
         fps = min(info.fps, @drawing_fps),
         height = Decoder.target_height(info.width, info.height, @work_width),
         {:ok, enc} <- Encoder.open(out_path, @work_width, height, fps, fps * 2) do
      total_estimate = max(round(info.duration_s * fps), 1)
      reduced = encode_frames(in_path, enc, fps, height, total_estimate, opts, progress_cb)

      with {:ok, stats} <- finish_render(reduced, enc, fps, height) do
        progress_cb.(stats.count, stats.count)
        {:ok, stats}
      end
    end
  end

  defp encode_frames(in_path, enc, fps, height, total_estimate, opts, progress_cb) do
    initial = %{mask_f: nil, trail: nil, split_ema: nil, count: 0, first: nil}

    in_path
    |> Decoder.stream!(%{width: @work_width, height: height, fps: fps})
    |> Enum.reduce_while(initial, &encode_step(&1, &2, opts, enc, total_estimate, progress_cb))
  end

  defp encode_step(frame, state, opts, enc, total_estimate, progress_cb) do
    case process_frame(frame, state, opts, enc) do
      {:ok, new_state} ->
        progress_cb.(new_state.count, max(total_estimate, new_state.count))
        {:cont, new_state}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp finish_render({:error, reason}, enc, _fps, _height) do
    _ = Encoder.close(enc)
    {:error, reason}
  end

  defp finish_render(%{count: 0}, enc, _fps, _height) do
    _ = Encoder.close(enc)
    {:error, "nenhum frame decodificado"}
  end

  defp finish_render(state, enc, fps, height) do
    with :ok <- Encoder.close(enc) do
      {:ok, %{count: state.count, fps: fps, height: height, first: state.first}}
    end
  end

  defp process_frame(frame, state, opts, enc) do
    with {:ok, raw_mask} <- segment(frame, opts) do
      prev_bin = binarize(state.mask_f)
      component = Mask.consistent_component(raw_mask, prev_bin)
      mask_f = component |> to_unit_f32() |> Mask.ema(state.mask_f, @mask_ema_alpha)
      mask_bin = binarize(mask_f)

      edges = frame |> Neon.trace_edges(mask_bin, detail: opts.detail) |> to_unit_f32()

      trail =
        case state.trail do
          nil -> edges
          prev -> Nx.max(edges, Nx.multiply(prev, opts.trail_decay))
        end

      {split_ema, weights} = duotone(mask_bin, state.split_ema, opts)

      neon =
        Neon.compose(trail, opts.colors,
          halo: opts.halo,
          duotone_weights: weights,
          current_edges: edges
        )

      with :ok <- Encoder.write_frame(enc, neon) do
        {:ok,
         %{
           state
           | mask_f: mask_f,
             trail: trail,
             split_ema: split_ema,
             count: state.count + 1,
             first: state.first || {frame, neon}
         }}
      end
    end
  end

  # cena escura (luma média < 70): clareia SÓ a entrada da segmentação;
  # as bordas continuam vindo do frame original (igual ao protótipo Python)
  defp segment(frame, opts) do
    seg_in =
      if luma(frame) < @dark_luma_threshold do
        frame
        |> Nx.as_type(:f32)
        |> Nx.multiply(1.4)
        |> Nx.add(18)
        |> Nx.clip(0, 255)
        |> Nx.as_type(:u8)
      else
        frame
      end

    opts.segmenter.segment(seg_in, model: opts.model)
  end

  defp luma(frame), do: frame |> Nx.as_type(:f32) |> Nx.mean() |> Nx.to_number()

  defp duotone(_mask_bin, split_ema, %{mode: :mono}), do: {split_ema, nil}

  defp duotone(mask_bin, split_ema, %{mode: :duotone}) do
    {h, w} = Nx.shape(mask_bin)
    split_now = Neon.mask_median_x(mask_bin)

    split =
      case split_ema do
        nil -> split_now
        prev -> @split_ema_prev * prev + @split_ema_curr * split_now
      end

    {split, Neon.duotone_weights(h, w, split, @duotone_blend_px)}
  end

  defp binarize(nil), do: nil

  defp binarize(mask_f) do
    mask_f
    |> Nx.greater(@mask_bin_threshold)
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
  end

  defp to_unit_f32(u8), do: u8 |> Nx.as_type(:f32) |> Nx.divide(255.0)

  defp build_opts(manifest) do
    params = manifest["params"] || %{}
    preset = Palette.get(manifest["preset"]) || Palette.get("forro-duotone")

    colors =
      if preset.mode == :duotone and params["swap_sides"] == true,
        do: Enum.reverse(preset.colors),
        else: preset.colors

    %{
      segmenter: Application.fetch_env!(:camerex, :segmenter),
      model: params["model"] || "u2net",
      detail: params["detail"] || 0.5,
      halo: params["halo"] || 0.6,
      trail_decay: params["trail"] || 0.7,
      mode: preset.mode,
      colors: colors
    }
  end

  # variante de build_opts para a CLI (keyword em vez de manifest)
  defp build_opts_kw(opts) do
    preset =
      Palette.get(Keyword.get(opts, :preset, "forro-teal")) || Palette.get("forro-teal")

    colors =
      if preset.mode == :duotone and Keyword.get(opts, :swap_sides, false),
        do: Enum.reverse(preset.colors),
        else: preset.colors

    %{
      segmenter: Application.fetch_env!(:camerex, :segmenter),
      model: Keyword.get(opts, :model, "u2netp"),
      detail: Keyword.get(opts, :detail, 0.5),
      halo: Keyword.get(opts, :halo, 0.6),
      trail_decay: Keyword.get(opts, :trail, 0.7),
      mode: preset.mode,
      colors: colors
    }
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)

  # thumbs de vídeo saem do primeiro frame processado (Workspace.write_thumbs
  # é orientado a foto: lê original.*/neon.* do disco, o que não serve aqui)
  defp write_video_thumbs(_item_id, nil), do: :ok

  defp write_video_thumbs(item_id, {original, neon}) do
    write_thumb(item_id, "thumb.jpg", original)
    write_thumb(item_id, "thumb_neon.jpg", neon)
  end

  defp write_thumb(item_id, file, rgb) do
    {h, w, 3} = Nx.shape(rgb)
    scale = min(480 / max(w, h), 1.0)
    {tw, th} = {max(round(w * scale), 2), max(round(h * scale), 2)}

    rgb
    |> Evision.Mat.from_nx_2d()
    |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2BGR())
    |> Evision.resize({tw, th}, interpolation: Evision.Constant.cv_INTER_AREA())
    |> then(&Evision.imwrite(Workspace.item_path(item_id, file), &1))

    :ok
  end
end
