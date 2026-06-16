defmodule Camerex.Pipeline.Video do
  @moduledoc """
  Pipeline de vídeo neon: probe → decode → por frame (segmentação com
  componente consistente, EMA anti-flicker, rastro de luz, duotone com
  split estabilizado) → encode H.264.

  **Map paralelo + scan sequencial.** A parte cara de cada frame (inferência
  ATR/U²-Net, arte-de-linha, campo de cor) é independente entre frames, então
  roda em paralelo via `Task.Supervisor.async_stream_nolink` (inferência ONNX é
  thread-safe — ver `Camerex.Segmenter.Ortex`). O estado temporal (rastro, EMAs
  de máscara/campo, split duotone) atravessa os frames num scan **sequencial e
  em ordem** — `compose_step/4` — então a saída é idêntica à do reduce serial,
  só mais rápida. `ordered: true` + `max_concurrency` mantêm a memória limitada
  a ~`frame_concurrency` frames em voo.

  Os tensores são materializados em `Nx.BinaryBackend` na fronteira das tasks:
  o frame vem do decoder no backend default (EXLA, device-resident) e cruzar
  processos com isso é frágil — e a composição já é toda Evision/binária, então
  hospedar é seguro e neutro em custo.
  """

  alias Camerex.{Mask, Neon, Parser, Settings, Workspace}
  alias Camerex.Neon.{Layered, Palette}
  alias Camerex.Parser.{Layers, Object}
  alias Camerex.Video.{Decoder, Encoder, Probe}

  @work_width 640
  # cadência "shot on twos" da animação à mão: até 12 desenhos/s, cada um
  # segurado por 2 frames no container (playback = 2 × desenhos)
  @drawing_fps 12.0
  @mask_ema_alpha 0.45
  @mask_bin_threshold 0.45
  @split_ema_prev 0.9
  @split_ema_curr 0.1
  # cor-por-parte: peso do frame anterior na EMA do campo de cor (anti-tremor
  # da rotulagem, que é parseada de forma independente por frame)
  @field_ema_alpha 0.5
  @dark_luma_threshold 70
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
    initial = %{mask_f: nil, trail: nil, split_ema: nil, field: nil, count: 0, first: nil}

    # frame vem em EXLA (Nx.from_binary); hospeda no BEAM antes de cruzar p/ as
    # tasks (device-resident não atravessa processo com segurança)
    frames =
      in_path
      |> Decoder.stream!(%{width: @work_width, height: height, fps: fps})
      |> Stream.map(&to_host(&1))

    Camerex.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(frames, &prepare_frame(&1, opts),
      max_concurrency: opts.frame_concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while(initial, &compose_reduce(&1, &2, opts, enc, total_estimate, progress_cb))
  end

  # scan SEQUENCIAL e em ordem sobre os frames já preparados em paralelo: aplica
  # o estado temporal, compõe e grava. async_stream entrega {:ok, valor} ou
  # {:exit, motivo} (crash da task); prepare_frame devolve {:ok, _} | {:error, _}.
  defp compose_reduce({:ok, {:ok, prepared}}, state, opts, enc, total_estimate, progress_cb) do
    case compose_step(prepared, state, opts, enc) do
      {:ok, new_state} ->
        progress_cb.(new_state.count, max(total_estimate, new_state.count))
        {:cont, new_state}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp compose_reduce({:ok, {:error, reason}}, _state, _o, _e, _t, _cb),
    do: {:halt, {:error, reason}}

  defp compose_reduce({:exit, reason}, _state, _o, _e, _t, _cb),
    do: {:halt, {:error, reason}}

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

  # cor-por-parte: arte-de-linha + campo de cor saem do Neon.Layered (MESMA
  # regra da foto), parseados por frame e estabilizados no tempo — rastro na
  # arte-de-linha, EMA no campo de cor. Não usa U²-Net: a silhueta vem da união
  # das partes do parser. Parsear todo frame é caro; é o preço da qualidade.
  # ── ESTÁGIO PARALELO ──────────────────────────────────────────────────────
  # parte cara e independente por frame. Roda numa task; materializa tudo em
  # BinaryBackend p/ cruzar de volta ao processo do scan com segurança.

  defp prepare_frame(frame, %{layered: true} = opts) do
    with {:ok, labels} <- Parser.parse(frame) do
      labels = object_labels(frame, labels, opts)
      {_h, w, _} = Nx.shape(frame)
      line = Layered.line_art(frame, labels, detail: opts.detail)
      raw_field = Layered.color_field(labels, opts.layer_colors, w)

      {:ok,
       %{
         kind: :layered,
         frame: to_host(frame),
         labels: to_host(labels),
         line: to_host(line),
         raw_field: to_host(raw_field)
       }}
    end
  end

  defp prepare_frame(frame, opts) do
    with {:ok, raw_mask} <- segment(frame, opts) do
      {:ok, %{kind: :plain, frame: to_host(frame), raw_mask: to_host(raw_mask)}}
    end
  end

  # ── ESTÁGIO SEQUENCIAL ────────────────────────────────────────────────────
  # estado temporal + composição + gravação, em ordem (mesma matemática do
  # reduce serial de antes — só a parte cara saiu para o estágio paralelo).

  defp compose_step(%{kind: :layered} = p, state, opts, enc) do
    field = Mask.ema(p.raw_field, state.field, @field_ema_alpha)

    trail =
      case state.trail do
        nil -> p.line
        prev -> Nx.max(p.line, Nx.multiply(prev, opts.trail_decay))
      end

    neon =
      Neon.compose(trail, [{0, 0, 0}],
        halo: opts.halo,
        bloom: opts.bloom,
        color_field: field,
        current_edges: p.line
      )
      |> fill_frame(opts, p.frame, p.labels, field)
      |> with_background(p.frame, opts)

    with :ok <- Encoder.write_frame(enc, neon) do
      {:ok,
       %{
         state
         | trail: trail,
           field: field,
           count: state.count + 1,
           first: state.first || {p.frame, neon}
       }}
    end
  end

  defp compose_step(%{kind: :plain} = p, state, opts, enc) do
    prev_bin = binarize(state.mask_f)
    component = Mask.consistent_component(p.raw_mask, prev_bin)
    mask_f = component |> to_unit_f32() |> Mask.ema(state.mask_f, @mask_ema_alpha)
    mask_bin = binarize(mask_f)

    edges =
      p.frame
      |> Neon.trace_edges(mask_bin, detail: opts.detail, chroma: opts.chroma)
      |> to_unit_f32()

    trail =
      case state.trail do
        nil -> edges
        prev -> Nx.max(edges, Nx.multiply(prev, opts.trail_decay))
      end

    {split_ema, weights} = color_weights(mask_bin, state.split_ema, opts)

    neon =
      Neon.compose(trail, opts.colors,
        halo: opts.halo,
        bloom: opts.bloom,
        duotone_weights: weights,
        current_edges: edges
      )
      |> with_background(p.frame, opts)

    with :ok <- Encoder.write_frame(enc, neon) do
      {:ok,
       %{
         state
         | mask_f: mask_f,
           trail: trail,
           split_ema: split_ema,
           count: state.count + 1,
           first: state.first || {p.frame, neon}
       }}
    end
  end

  # hospeda o tensor no BEAM (BinaryBackend): no-op se já estiver lá; senão copia
  # do device (EXLA) p/ poder trafegar entre processos. Barato — a composição já
  # é toda Evision/binária.
  defp to_host(tensor), do: Nx.backend_transfer(tensor, Nx.BinaryBackend)

  # preenchimento texturizado SOB as linhas no cor-por-parte (mesma regra da
  # foto). field aqui já é o campo de cor com EMA; a textura vem do frame.
  defp fill_frame(neon, %{fill: true} = opts, frame, labels, field) do
    fill =
      Layered.texture_fill(frame, field, labels,
        color: opts.fill_color,
        texture: opts.fill_texture
      )

    neon |> Nx.as_type(:f32) |> Nx.max(fill) |> Nx.clip(0, 255) |> Nx.as_type(:u8)
  end

  defp fill_frame(neon, _opts, _frame, _labels, _field), do: neon

  # original atenuado ATRÁS do neon (mesma regra da foto): a cena real aparece
  # fantasma sob o traço. Vídeo não tem alpha — só este modo de fundo se aplica.
  defp with_background(neon, frame, %{bg_opacity: op}) when is_number(op) and op > 0.0 do
    bg = frame |> Nx.as_type(:f32) |> Nx.multiply(op)
    neon |> Nx.as_type(:f32) |> Nx.max(bg) |> Nx.clip(0, 255) |> Nx.as_type(:u8)
  end

  defp with_background(neon, _frame, _opts), do: neon

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

  # pesos de cor por frame. duotone usa split com EMA temporal (anti-tremor);
  # mono/gradiente vêm da regra compartilhada Neon.weights_for (gradiente
  # entrou na F1 — sem esta cláusula o vídeo crashava com Aurora/Brasa).
  defp color_weights(mask_bin, split_ema, %{mode: :duotone}) do
    split_now = Neon.mask_median_x(mask_bin)

    split =
      case split_ema do
        nil -> split_now
        prev -> @split_ema_prev * prev + @split_ema_curr * split_now
      end

    {split, Neon.weights_for(:duotone, mask_bin, split)}
  end

  defp color_weights(mask_bin, split_ema, %{mode: mode}) do
    {split_ema, Neon.weights_for(mode, mask_bin, 0.0)}
  end

  defp binarize(nil), do: nil

  defp binarize(mask_f) do
    mask_f
    |> Nx.greater(@mask_bin_threshold)
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
  end

  defp to_unit_f32(u8), do: u8 |> Nx.as_type(:f32) |> Nx.divide(255.0)

  # defaults dos ajustes por frame (merge de mapa em vez de `||` em cadeia —
  # mantém o credo feliz e os params num lugar só)
  @frame_defaults %{
    "detail" => 0.5,
    "chroma" => 0.0,
    "halo" => 0.6,
    "bloom" => 0.0,
    "trail" => 0.7
  }

  defp build_opts(manifest) do
    params = manifest["params"] || %{}
    preset = Palette.get(manifest["preset"]) || Palette.get("forro-duotone")
    p = Map.merge(Map.put(@frame_defaults, "model", "u2net"), params)
    frame_opts(p, preset, params["swap_sides"] == true)
  end

  # variante de build_opts para a CLI (keyword em vez de manifest)
  defp build_opts_kw(opts) do
    preset = Palette.get(Keyword.get(opts, :preset, "forro-teal")) || Palette.get("forro-teal")
    params = Map.new(opts, fn {k, v} -> {Atom.to_string(k), v} end)
    p = Map.merge(Map.put(@frame_defaults, "model", "u2netp"), params)
    frame_opts(p, preset, Keyword.get(opts, :swap_sides, false))
  end

  # monta o mapa de opções por frame a partir de params já com defaults
  defp frame_opts(p, preset, swap) do
    colors =
      if preset.mode == :duotone and swap, do: Enum.reverse(preset.colors), else: preset.colors

    %{
      segmenter: Application.fetch_env!(:camerex, :segmenter),
      model: p["model"],
      detail: p["detail"],
      chroma: p["chroma"],
      halo: p["halo"],
      bloom: p["bloom"],
      trail_decay: p["trail"],
      mode: preset.mode,
      colors: colors,
      layered: p["layered"] == true,
      layer_colors: Layers.normalize_colors(p["layer_colors"]),
      detect_object: p["detect_object"] == true,
      bg_opacity: p["bg_opacity"] || 0.0,
      fill: p["fill"] == true,
      fill_color: p["fill_color"] || 0.45,
      fill_texture: p["fill_texture"] || 0.15,
      frame_concurrency: resolve_frame_concurrency(p)
    }
  end

  # teto generoso pro controle ao vivo: o usuário pode sobre-assinar os cores e
  # monitorar no dashboard; acima disso é desperdício/risco de memória.
  @frame_concurrency_max 64

  @doc """
  Quantos frames preparar em paralelo (lido das Settings; default = nº de
  schedulers). Ajustável ao vivo pelo dashboard — vale para o PRÓXIMO vídeo
  (um job em andamento fixa a concorrência no início, via async_stream).
  """
  @spec frame_concurrency() :: pos_integer()
  def frame_concurrency, do: Settings.get("video_frame_concurrency", System.schedulers_online())

  @doc "Ajusta (clamp 1..#{@frame_concurrency_max}) e persiste; devolve o valor aplicado."
  @spec set_frame_concurrency(integer()) :: pos_integer()
  def set_frame_concurrency(n) do
    clamped = n |> max(1) |> min(@frame_concurrency_max)
    :ok = Settings.put("video_frame_concurrency", clamped)
    clamped
  end

  # resolução por job: param explícito do item (CLI/teste) > Settings/default
  defp resolve_frame_concurrency(p) do
    case p["frame_concurrency"] do
      n when is_integer(n) and n > 0 -> n
      _ -> frame_concurrency()
    end
  end

  # opt-in por frame: roda o U²-Net e injeta o objeto (instrumento etc.) como a
  # classe 18 (ver Camerex.Parser.Object). Custa uma passada a mais do segmenter
  # por frame — aceitável pelo ganho de qualidade (paraleliza-se depois).
  defp object_labels(frame, labels, %{detect_object: true} = opts) do
    case opts.segmenter.segment(frame, model: opts.model) do
      {:ok, raw} -> Object.into_labels(labels, Object.detect(Mask.largest_component(raw), labels))
      _ -> labels
    end
  end

  defp object_labels(_frame, labels, _opts), do: labels

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
