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
  alias Camerex.Neon.{Background, Layered}
  alias Camerex.Parser.{Apparatus, Hair, Layers, Object, Skin}
  alias Camerex.Video.{Audio, Decoder, Encoder, Probe}

  @work_width 640
  # cadência "shot on twos" da animação à mão: até 12 desenhos/s, cada um
  # segurado por 2 frames no container (playback = 2 × desenhos)
  @drawing_fps 12.0
  # cor-por-parte: peso do frame anterior na EMA do campo de cor (anti-tremor
  # da rotulagem, que é parseada de forma independente por frame)
  @field_ema_alpha 0.5
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

  opts (defaults do contrato): `halo:` 0.6, `detail:` 0.5, `trail:` 0.7,
  `model:` "u2netp". Cor por camada via `layer_colors` (defaults de Layers).
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
        # reanexa o áudio do original (mudo se a origem não tiver)
        Audio.attach(out_path, in_path)
        progress_cb.(stats.count, stats.count)
        {:ok, stats}
      end
    end
  end

  defp encode_frames(in_path, enc, fps, height, total_estimate, opts, progress_cb) do
    initial = %{trail: nil, field: nil, count: 0, first: nil}

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

  defp prepare_frame(frame, opts) do
    with {:ok, labels} <- Parser.parse(frame) do
      labels = augment_frame_labels(frame, labels, opts)
      {_h, w, _} = Nx.shape(frame)
      line = Layered.line_art(frame, labels, detail: opts.detail)
      raw_field = Layered.color_field(labels, opts.layer_colors, w)

      {:ok,
       %{
         frame: to_host(frame),
         labels: to_host(labels),
         line: to_host(line),
         raw_field: to_host(raw_field)
       }}
    end
  end

  # ── ESTÁGIO SEQUENCIAL ────────────────────────────────────────────────────
  # estado temporal + composição + gravação, em ordem (mesma matemática do
  # reduce serial de antes — só a parte cara saiu para o estágio paralelo).

  defp compose_step(p, state, opts, enc) do
    field = Mask.ema(p.raw_field, state.field, @field_ema_alpha)

    trail =
      case state.trail do
        nil -> p.line
        prev -> Nx.max(p.line, Nx.multiply(prev, opts.trail_decay))
      end

    neon =
      Neon.compose(trail,
        halo: opts.halo,
        bloom: opts.bloom,
        color_field: field,
        current_edges: p.line
      )
      |> fill_frame(opts, p.frame, p.labels, field)
      |> Background.behind(p.frame, opts.bg_opacity)

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

  # defaults dos ajustes por frame (merge de mapa em vez de `||` em cadeia —
  # mantém o credo feliz e os params num lugar só)
  @frame_defaults %{
    "detail" => 0.5,
    "halo" => 0.6,
    "bloom" => 0.0,
    "trail" => 0.7
  }

  defp build_opts(manifest) do
    params = manifest["params"] || %{}
    frame_opts(Map.merge(Map.put(@frame_defaults, "model", "u2net"), params))
  end

  # variante de build_opts para a CLI (keyword em vez de manifest)
  defp build_opts_kw(opts) do
    params = Map.new(opts, fn {k, v} -> {Atom.to_string(k), v} end)
    frame_opts(Map.merge(Map.put(@frame_defaults, "model", "u2netp"), params))
  end

  # monta o mapa de opções por frame a partir de params já com defaults.
  # `model` é só pro detect_object (U²-Net); a cor-por-parte usa o parser (ATR).
  defp frame_opts(p) do
    %{
      segmenter: Application.fetch_env!(:camerex, :segmenter),
      model: p["model"],
      detail: p["detail"],
      halo: p["halo"],
      bloom: p["bloom"],
      trail_decay: p["trail"],
      layer_colors: Layers.normalize_colors(p["layer_colors"]),
      detect_object: p["detect_object"] == true,
      detect_hair: p["detect_hair"] == true,
      hair_color: p["hair_color"],
      hair_model: p["hair_model"],
      hair_sensitivity: p["hair_sensitivity"] || 0.5,
      detect_aerial: p["detect_aerial"] == true,
      aerial_color: p["aerial_color"],
      aerial_sensitivity: p["aerial_sensitivity"] || 0.5,
      detect_skin: p["detect_skin"] == true,
      skin_sensitivity: p["skin_sensitivity"] || 0.5,
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

  # opt-in por frame: injeta as classes virtuais — objeto na mão (18, no model do
  # item) e/ou tecido aéreo (19, no `u2netp`, que pega o drapeado que o u2net
  # perde). Cada feature ligada custa uma passada do segmenter (paralelizado).
  defp augment_frame_labels(frame, labels, opts) do
    labels
    |> frame_object(frame, opts.segmenter, opts.model, opts.detect_object)
    |> frame_hair(
      frame,
      opts.segmenter,
      opts.hair_model || opts.hair_color,
      opts.hair_sensitivity,
      opts.detect_hair
    )
    |> frame_aerial(
      frame,
      opts.segmenter,
      opts.aerial_color,
      opts.aerial_sensitivity,
      opts.detect_aerial
    )
    |> frame_skin(frame, opts.detect_skin, opts.skin_sensitivity)
  end

  # pele do torço nu → pele (por último, sem U²-Net; modelo aprendido dos labels
  # ATR daquele frame, que são estáveis frame a frame). Ver Parser.Skin.
  defp frame_skin(labels, _frame, false, _sens), do: labels

  defp frame_skin(labels, frame, true, sens),
    do: Skin.into_labels(labels, Skin.detect(labels, frame, sensitivity: sens))

  defp frame_object(labels, _frame, _seg, _model, false), do: labels

  defp frame_object(labels, frame, segmenter, model, true) do
    case segmenter.segment(frame, model: model) do
      {:ok, raw} -> Object.into_labels(labels, Object.detect(Mask.largest_component(raw), labels))
      _ -> labels
    end
  end

  # cabelo: FALLBACK por cor só quando o ATR não enxerga cabeça no frame E há cor
  # indicada (silhueta = maior componente do u2net; ver Parser.Hair)
  defp frame_hair(labels, _frame, _seg, nil, _sens, _on), do: labels
  defp frame_hair(labels, _frame, _seg, _color, _sens, false), do: labels

  defp frame_hair(labels, frame, segmenter, color, sens, true) do
    if Hair.present?(labels) do
      labels
    else
      case segmenter.segment(frame, model: "u2net") do
        {:ok, raw} ->
          mask =
            Hair.detect(Mask.largest_component(raw), labels, frame, color,
              sensitivity: sens,
              spatial: false
            )

          Hair.into_labels(labels, mask)

        _ ->
          labels
      end
    end
  end

  # tecido usa o foreground COMPLETO do u2netp (todos os componentes); a cor do
  # tecido (aerial_color) enriquece a saliência
  defp frame_aerial(labels, _frame, _seg, _color, _sens, false), do: labels

  defp frame_aerial(labels, frame, segmenter, color, sens, true) do
    case segmenter.segment(frame, model: "u2netp") do
      {:ok, raw} ->
        full = raw |> Nx.greater(0) |> Nx.multiply(255) |> Nx.as_type(:u8)
        mask = Apparatus.detect(full, labels, frame, color, sensitivity: sens)
        Apparatus.into_labels(labels, mask)

      _ ->
        labels
    end
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
