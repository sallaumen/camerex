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
  @max_fps 15.0
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
    result =
      with {:ok, manifest} <- Workspace.manifest(item_id),
           in_path = Workspace.item_path(item_id, manifest["original_file"]),
           {:ok, info} <- Probe.probe(in_path) do
        convert(item_id, manifest, in_path, info, progress_cb)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Workspace.update_manifest(item_id, fn m ->
          Map.merge(m, %{"status" => "failed", "error" => error_message(reason)})
        end)

        {:error, reason}
    end
  end

  defp convert(item_id, manifest, in_path, info, progress_cb) do
    started = System.monotonic_time(:millisecond)
    fps = min(info.fps, @max_fps)
    height = Decoder.target_height(info.width, info.height, @work_width)
    total_estimate = max(round(info.duration_s * fps), 1)
    out_path = Workspace.item_path(item_id, @output_file)
    opts = build_opts(manifest)

    with {:ok, enc} <- Encoder.open(out_path, @work_width, height, fps) do
      initial = %{mask_f: nil, trail: nil, split_ema: nil, count: 0, first: nil}

      reduced =
        in_path
        |> Decoder.stream!(%{width: @work_width, height: height, fps: fps})
        |> Enum.reduce_while(initial, fn frame, state ->
          case process_frame(frame, state, opts, enc) do
            {:ok, new_state} ->
              progress_cb.(new_state.count, max(total_estimate, new_state.count))
              {:cont, new_state}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      finish(reduced, enc, item_id, fps, height, started, progress_cb)
    end
  end

  defp finish({:error, reason}, enc, _item_id, _fps, _height, _started, _cb) do
    _ = Encoder.close(enc)
    {:error, reason}
  end

  defp finish(%{count: 0}, enc, _item_id, _fps, _height, _started, _cb) do
    _ = Encoder.close(enc)
    {:error, "nenhum frame decodificado"}
  end

  defp finish(state, enc, item_id, fps, height, started, progress_cb) do
    with :ok <- Encoder.close(enc) do
      write_video_thumbs(item_id, state.first)
      total_ms = System.monotonic_time(:millisecond) - started
      progress_cb.(state.count, state.count)

      {:ok, _} =
        Workspace.update_manifest(item_id, fn m ->
          Map.merge(m, %{
            "status" => "done",
            "output_file" => @output_file,
            "completed_at" => DateTime.to_iso8601(DateTime.now!("America/Sao_Paulo")),
            "media" => %{
              "width" => @work_width,
              "height" => height,
              "frames" => state.count,
              "fps" => fps,
              "duration_s" => state.count / fps
            },
            "timings_ms" => %{
              "total" => total_ms,
              "per_frame_avg" => Float.round(total_ms / state.count, 1)
            }
          })
        end)

      :ok
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
