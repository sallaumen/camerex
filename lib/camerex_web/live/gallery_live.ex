defmodule CamerexWeb.GalleryLive do
  use CamerexWeb, :live_view

  alias Camerex.Jobs
  alias Camerex.Neon.Palette
  alias Camerex.Workspace

  @video_exts ~w(.mp4 .mov .m4v .webm)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Jobs.subscribe()

    socket =
      socket
      |> assign(
        presets: Palette.all(),
        preset_id: "forro-laranja",
        halo: 0.6,
        trail: 0.7,
        detail: 0.5,
        swap_sides: false,
        preview_data_url: nil,
        preview_error: nil,
        progress: %{},
        subscribed_jobs: MapSet.new()
      )
      # params exatos do contrato §8; auto_upload: o arquivo sobe na seleção
      # (progresso aparece na hora e a prévia funciona antes do submit)
      |> allow_upload(:media,
        accept: ~w(.jpg .jpeg .png .webp .mp4 .mov .m4v .webm),
        max_file_size: 600_000_000,
        chunk_size: 640_000,
        chunk_timeout: 60_000,
        max_entries: 1,
        auto_upload: true
      )
      |> load_items()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:jobs_changed}, socket), do: {:noreply, load_items(socket)}

  def handle_info({:job_progress, id, prog}, socket) do
    {:noreply, assign(socket, progress: Map.put(socket.assigns.progress, id, prog))}
  end

  @impl true
  def handle_event("select_preset", %{"id" => id}, socket) do
    swap =
      if duotone?(id), do: socket.assigns.swap_sides, else: false

    {:noreply, assign(socket, preset_id: id, swap_sides: swap)}
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign_controls(socket, params)}
  end

  def handle_event("preview_frame", _params, socket) do
    # consume com entry em progresso derruba o LiveView (bug pego no
    # checkpoint 4.9): com auto_upload o done? chega sozinho, mas o clique
    # pode vir antes — nesse caso, avisa em vez de crashar
    if Enum.all?(socket.assigns.uploads.media.entries, & &1.done?) do
      do_preview_frame(socket)
    else
      {:noreply, assign(socket, preview_error: "aguarde o upload terminar")}
    end
  end

  defp do_preview_frame(socket) do
    results =
      consume_uploaded_entries(socket, :media, fn %{path: path}, _entry ->
        # :postpone lê o tmp do upload SEM consumi-lo — o arquivo continua
        # disponível para o submit de conversão de verdade
        {:postpone, generate_preview(path, current_params(socket))}
      end)

    case results do
      [{:ok, data_url} | _] ->
        {:noreply, assign(socket, preview_data_url: data_url, preview_error: nil)}

      [{:error, reason} | _] ->
        {:noreply, assign(socket, preview_data_url: nil, preview_error: error_message(reason))}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_event("convert", params, socket) do
    socket = assign_controls(socket, params)

    ids =
      consume_uploaded_entries(socket, :media, fn %{path: path}, entry ->
        type = media_type(entry.client_name)

        item_params = %{
          "halo" => socket.assigns.halo,
          "trail" => socket.assigns.trail,
          "detail" => socket.assigns.detail,
          "swap_sides" => socket.assigns.swap_sides,
          "model" => default_model(type)
        }

        {:ok, id} =
          Workspace.create_item(
            path,
            entry.client_name,
            type,
            socket.assigns.preset_id,
            item_params
          )

        {:ok, id}
      end)

    case ids do
      [] ->
        {:noreply, put_flash(socket, :error, "Escolha uma foto ou vídeo para converter.")}

      ids ->
        Enum.each(ids, &Jobs.enqueue/1)
        {:noreply, socket |> load_items() |> push_patch(to: ~p"/")}
    end
  end

  defp load_items(socket) do
    items = Workspace.list_items()

    socket
    |> assign(:items, items)
    |> subscribe_processing(items)
  end

  # assina o tópico job:<id> de cada item processing; o MapSet evita
  # assinatura duplicada quando {:jobs_changed} recarrega a lista
  defp subscribe_processing(socket, items) do
    subscribed = socket.assigns[:subscribed_jobs] || MapSet.new()

    new_ids =
      items
      |> Enum.filter(&(&1["status"] == "processing"))
      |> Enum.map(& &1["id"])
      |> MapSet.new()
      |> MapSet.difference(subscribed)

    Enum.each(new_ids, &Jobs.subscribe/1)
    assign(socket, subscribed_jobs: MapSet.union(subscribed, new_ids))
  end

  defp progress_pct(%{done: d, total: t}) when t > 0, do: Float.round(d / t * 100, 1)
  defp progress_pct(_), do: 0.0

  defp duotone?(preset_id) do
    case Palette.get(preset_id) do
      %{mode: :duotone} -> true
      _ -> false
    end
  end

  defp assign_controls(socket, params) do
    assign(socket,
      halo: parse_slider(params["halo"], socket.assigns.halo),
      trail: parse_slider(params["trail"], socket.assigns.trail),
      detail: parse_slider(params["detail"], socket.assigns.detail),
      swap_sides: params["swap_sides"] == "true"
    )
  end

  defp parse_slider(nil, fallback), do: fallback

  defp parse_slider(value, fallback) do
    case Float.parse(value) do
      {f, _rest} -> f
      :error -> fallback
    end
  end

  defp media_type(filename) do
    if Path.extname(String.downcase(filename)) in @video_exts, do: :video, else: :photo
  end

  # u2net para tudo (decisão do gate da Fase 0: 1,9x de speedup não bateu o
  # critério de 2x); u2netp fica para o toggle "modo rápido" e para a prévia
  defp default_model(:photo), do: "u2net"
  defp default_model(:video), do: "u2net"

  # prévia usa u2netp: é descartável e a velocidade importa mais que a
  # fidelidade absoluta ao modelo final
  defp current_params(socket) do
    [
      preset: socket.assigns.preset_id,
      halo: socket.assigns.halo,
      detail: socket.assigns.detail,
      swap_sides: socket.assigns.swap_sides,
      model: "u2netp"
    ]
  end

  defp generate_preview(video_path, opts) do
    tmp_png =
      Path.join(
        Camerex.Workspace.tmp_dir(),
        "preview-#{System.unique_integer([:positive])}.png"
      )

    File.mkdir_p!(Path.dirname(tmp_png))

    with {:ok, info} <- Camerex.Video.Probe.probe(video_path),
         :ok <- extract_middle_frame(video_path, info.duration_s / 2, tmp_png),
         {:ok, data_url} <- render_preview_frame(tmp_png, opts) do
      File.rm(tmp_png)
      {:ok, data_url}
    end
  end

  defp extract_middle_frame(video_path, ss, out_png) do
    args = ["-y", "-v", "error", "-ss", "#{ss}", "-i", video_path, "-frames:v", "1", out_png]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> {:error, "ffmpeg falhou (status #{status}): #{String.trim(out)}"}
    end
  end

  defp render_preview_frame(png_path, opts) do
    rgb =
      png_path
      |> Evision.imread()
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)

    with {:ok, neon} <- Camerex.Pipeline.Photo.render(rgb, opts) do
      mat =
        neon
        |> Evision.Mat.from_nx_2d()
        |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2BGR())

      case Evision.imencode(".png", mat) do
        bin when is_binary(bin) ->
          {:ok, "data:image/png;base64," <> Base.encode64(bin)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp video_upload_selected?(upload) do
    Enum.any?(upload.entries, &String.starts_with?(&1.client_type || "", "video/"))
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)

  defp upload_error_label(:too_large), do: "arquivo grande demais (máx. 600 MB)"
  defp upload_error_label(:not_accepted), do: "formato não suportado"
  defp upload_error_label(:too_many_files), do: "envie 1 arquivo por vez"
  defp upload_error_label(other), do: inspect(other)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-6xl p-6">
        <h1 class="text-2xl font-semibold">camerex</h1>

        <form
          id="convert-form"
          phx-submit="convert"
          phx-change="validate"
          class="mt-6 rounded-lg border border-cx-border bg-cx-surface p-4"
        >
          <div
            phx-drop-target={@uploads.media.ref}
            class="rounded border border-dashed border-cx-border p-4"
          >
            <.live_file_input upload={@uploads.media} />
            <p :for={err <- upload_errors(@uploads.media)} class="mt-1 text-sm text-red-300">
              {upload_error_label(err)}
            </p>
            <div
              :for={entry <- @uploads.media.entries}
              data-role="upload-entry"
              class="mt-2 text-sm text-cx-text-dim"
            >
              {entry.client_name} — {entry.progress}%
              <p :for={err <- upload_errors(@uploads.media, entry)} class="text-red-300">
                {upload_error_label(err)}
              </p>
            </div>

            <button
              :if={video_upload_selected?(@uploads.media)}
              type="button"
              phx-click="preview_frame"
              data-role="preview-button"
              class="mt-2 rounded border border-cx-border px-3 py-1.5 text-sm hover:border-cx-teal"
            >
              Prévia de 1 frame
            </button>

            <img
              :if={@preview_data_url}
              src={@preview_data_url}
              alt="prévia neon do frame do meio"
              data-role="preview-img"
              class="mt-2 max-h-64 rounded"
            />

            <p :if={@preview_error} class="mt-2 text-sm text-cx-orange">
              Prévia falhou: {@preview_error}
            </p>
          </div>

          <fieldset id="preset-swatches" class="mt-4 flex flex-wrap gap-2">
            <button
              :for={preset <- @presets}
              type="button"
              phx-click="select_preset"
              phx-value-id={preset.id}
              data-selected={to_string(preset.id == @preset_id)}
              title={preset.name}
              class={[
                "flex h-9 items-center rounded-full border px-3 text-xs",
                (preset.id == @preset_id && "border-cx-text") || "border-cx-border"
              ]}
            >
              <span
                :for={{r, g, b} <- preset.colors}
                class="mr-1 inline-block h-4 w-4 rounded-full"
                style={"background-color: rgb(#{r}, #{g}, #{b})"}
              ></span>
              {preset.name}
            </button>
          </fieldset>

          <div class="mt-4 grid grid-cols-1 gap-4 text-sm sm:grid-cols-3">
            <label>
              halo ({@halo})
              <input
                type="range"
                name="halo"
                min="0"
                max="1"
                step="0.05"
                value={@halo}
                class="w-full"
              />
            </label>
            <label>
              rastro ({@trail})
              <input
                type="range"
                name="trail"
                min="0"
                max="0.95"
                step="0.05"
                value={@trail}
                class="w-full"
              />
            </label>
            <label>
              detalhe ({@detail})
              <input
                type="range"
                name="detail"
                min="0"
                max="1"
                step="0.05"
                value={@detail}
                class="w-full"
              />
            </label>
          </div>

          <label
            :if={duotone?(@preset_id)}
            id="swap-sides"
            class="mt-3 flex items-center gap-2 text-sm"
          >
            <input type="hidden" name="swap_sides" value="false" />
            <input type="checkbox" name="swap_sides" value="true" checked={@swap_sides} />
            inverter lados
          </label>

          <button type="submit" class="mt-4 rounded bg-cx-teal px-4 py-2 font-medium text-cx-bg">
            Converter
          </button>
        </form>

        <section id="gallery" class="mt-8 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <article
            :for={item <- @items}
            id={"item-#{item["id"]}"}
            class="rounded-lg border border-cx-border bg-cx-surface p-3"
          >
            <.link navigate={"/item/#{item["id"]}"} class="block">
              <div :if={item["status"] == "done"} class="flex gap-2">
                <img
                  src={Workspace.media_url(item["id"], "thumb.jpg")}
                  alt="antes"
                  class="w-1/2 rounded object-cover"
                />
                <img
                  src={Workspace.media_url(item["id"], "thumb_neon.jpg")}
                  alt="depois"
                  class="w-1/2 rounded object-cover"
                />
              </div>
              <div
                :if={item["status"] != "done"}
                data-role="placeholder"
                class="flex h-24 items-center justify-center rounded bg-cx-bg text-sm text-cx-text-dim"
              >
                {item["original_filename"]}
              </div>
            </.link>

            <div class="mt-2 flex items-center gap-2 text-xs">
              <span data-role="type-chip" class="rounded-full border border-cx-border px-2 py-0.5">
                {type_label(item["type"])}
              </span>
              <span
                data-role="status-chip"
                class={["rounded-full px-2 py-0.5", status_class(item["status"])]}
              >
                {status_label(item["status"])}
              </span>
            </div>

            <div
              :if={item["status"] == "processing"}
              data-role="job-progress"
              data-item-id={item["id"]}
              class="mt-2"
            >
              <%= if prog = @progress[item["id"]] do %>
                <div class="h-1.5 rounded bg-cx-border">
                  <div class="h-1.5 rounded bg-cx-teal" style={"width: #{progress_pct(prog)}%"}></div>
                </div>
                <span class="text-xs text-cx-text-dim">
                  {prog.done}/{prog.total}{if prog.eta_s, do: " · ~#{round(prog.eta_s)}s"}
                </span>
              <% else %>
                <span class="text-xs text-cx-text-dim">processando…</span>
              <% end %>
            </div>
            <p
              :if={item["error"]}
              class="mt-1 truncate text-xs text-cx-text-dim"
              title={item["error"]}
            >
              {item["error"]}
            </p>
          </article>
        </section>

        <p :if={@items == []} id="gallery-empty" class="mt-8 text-cx-text-dim">
          Nenhuma conversão ainda — envie uma foto para começar.
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp type_label("video"), do: "vídeo"
  defp type_label(_), do: "foto"

  defp status_label("queued"), do: "na fila"
  defp status_label("processing"), do: "processando"
  defp status_label("done"), do: "pronto"
  defp status_label("failed"), do: "falhou"
  defp status_label("interrupted"), do: "interrompido"
  defp status_label(other), do: other

  defp status_class("done"), do: "bg-cx-teal/20 text-cx-teal"
  defp status_class("processing"), do: "bg-cx-orange/20 text-cx-orange"
  defp status_class("failed"), do: "bg-red-500/20 text-red-300"
  defp status_class("interrupted"), do: "bg-yellow-500/20 text-yellow-200"
  defp status_class(_), do: "bg-cx-bg text-cx-text-dim"
end
