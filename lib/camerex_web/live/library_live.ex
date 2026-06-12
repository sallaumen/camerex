defmodule CamerexWeb.LibraryLive do
  @moduledoc """
  A biblioteca inteira numa página: rail de pastas/presets à esquerda, grid
  com seleção múltipla no centro e painel de conversão/detalhe à direita.
  Navegação por `push_patch` (`?folder=&item=`) — nada de troca de página.
  """

  use CamerexWeb, :live_view

  import CamerexWeb.ConvertPanel
  import CamerexWeb.DetailPanel
  import CamerexWeb.LibraryComponents

  alias Camerex.{Jobs, Library, Settings, UserPresets, Workspace}
  alias Camerex.Library.Import, as: LibraryImport
  alias Camerex.Neon.Palette
  alias Camerex.Pipeline.FramePreview

  @video_exts ~w(.mp4 .mov .m4v .webm)

  ## Mount / params

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Jobs.subscribe()

    socket =
      socket
      |> assign(
        folder: "",
        items: [],
        tree: [],
        root_count: 0,
        selected: MapSet.new(),
        current_item: nil,
        reconvert_item: nil,
        modal: nil,
        import_path: "",
        import_scan: nil,
        new_folder_name: "",
        presets: Palette.all(),
        preset_id: "forro-laranja",
        halo: 0.6,
        trail: 0.7,
        detail: 0.5,
        swap_sides: false,
        preset_name: "",
        user_presets: UserPresets.all(),
        concurrency: Settings.get("concurrency", 3),
        preview_data_url: nil,
        preview_error: nil,
        progress: %{},
        subscribed_jobs: MapSet.new(),
        doctor_problems: doctor_problems(doctor_module().check())
      )
      |> allow_upload(:media,
        accept: ~w(.jpg .jpeg .png .webp .mp4 .mov .m4v .webm),
        max_file_size: 600_000_000,
        chunk_size: 640_000,
        chunk_timeout: 60_000,
        max_entries: 1,
        auto_upload: true
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    folder =
      case Workspace.normalize_folder(params["folder"] || "") do
        {:ok, folder} -> folder
        :error -> ""
      end

    {:noreply,
     socket
     |> assign(:folder, folder)
     |> assign_current_item(params["item"])
     |> reload()}
  end

  ## PubSub

  @impl true
  def handle_info({:jobs_changed}, socket) do
    {:noreply, socket |> reload() |> refresh_current_item()}
  end

  def handle_info({:job_progress, id, prog}, socket) do
    {:noreply, assign(socket, progress: Map.put(socket.assigns.progress, id, prog))}
  end

  ## Navegação e seleção

  @impl true
  def handle_event("select_folder", %{"folder" => folder}, socket) do
    {:noreply, patch_to(socket, folder: folder, item: nil)}
  end

  def handle_event("open_item", %{"id" => id}, socket) do
    {:noreply, patch_to(socket, item: id)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, socket |> assign(:reconvert_item, nil) |> patch_to(item: nil)}
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("select_all", _params, socket) do
    ids = socket.assigns.items |> Enum.map(& &1["id"]) |> MapSet.new()
    {:noreply, assign(socket, :selected, ids)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  ## Pastas (modais)

  def handle_event("open_modal", %{"modal" => "import"}, socket) do
    {:noreply, assign(socket, modal: :import, import_path: "", import_scan: nil)}
  end

  def handle_event("open_modal", %{"modal" => "new_folder"}, socket) do
    {:noreply, assign(socket, modal: :new_folder, new_folder_name: "")}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :modal, nil)}
  end

  def handle_event("create_folder", %{"name" => name}, socket) do
    base = socket.assigns.folder
    path = if base == "", do: name, else: "#{base}/#{name}"

    case Library.create_folder(path) do
      {:ok, folder} ->
        {:noreply, socket |> assign(:modal, nil) |> patch_to(folder: folder, item: nil)}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("delete_folder", %{"folder" => folder}, socket) do
    case Library.delete_folder(folder) do
      :ok ->
        {:noreply,
         socket |> put_flash(:info, "pasta removida") |> patch_to(folder: "", item: nil)}

      {:error, :not_empty} ->
        {:noreply, put_flash(socket, :error, "a pasta precisa estar vazia para ser removida")}
    end
  end

  ## Importação

  def handle_event("import_scan", %{"path" => path}, socket) do
    {:noreply, assign(socket, import_path: path, import_scan: LibraryImport.scan(path))}
  end

  def handle_event("import_run", _params, socket) do
    case LibraryImport.run(socket.assigns.import_path, socket.assigns.folder) do
      {:ok, %{imported: n, skipped: skipped}} ->
        {:noreply,
         socket
         |> assign(modal: nil, import_scan: nil)
         |> put_flash(:info, "#{n} mídia(s) importada(s), #{skipped} arquivo(s) ignorado(s)")
         |> reload()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  ## Painel de conversão (upload novo)

  def handle_event("select_preset", %{"id" => id}, socket) do
    swap = if duotone?(id), do: socket.assigns.swap_sides, else: false
    {:noreply, assign(socket, preset_id: id, swap_sides: swap)}
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign_controls(socket, params)}
  end

  def handle_event("convert", params, socket) do
    socket = assign_controls(socket, params)

    case socket.assigns.reconvert_item do
      nil -> convert_upload(socket)
      item -> reprocess_item(socket, item)
    end
  end

  def handle_event("preview_frame", _params, socket) do
    if Enum.all?(socket.assigns.uploads.media.entries, & &1.done?) do
      do_preview_frame(socket)
    else
      {:noreply, assign(socket, preview_error: "aguarde o upload terminar")}
    end
  end

  ## Reprocesso in-place

  def handle_event("reconvert_start", _params, socket) do
    item = socket.assigns.current_item

    socket =
      socket
      |> assign(:reconvert_item, item)
      |> apply_item_params(item)

    {:noreply, socket}
  end

  def handle_event("reconvert_cancel", _params, socket) do
    {:noreply, assign(socket, :reconvert_item, nil)}
  end

  def handle_event("retry_item", _params, socket) do
    item = socket.assigns.current_item
    params = Map.put(item["params"] || default_panel_params(socket), "preset", item["preset"])
    Library.process_items([item["id"]], params)
    {:noreply, socket |> reload() |> refresh_current_item()}
  end

  ## Ações do item em detalhe

  def handle_event("duplicate_item", _params, socket) do
    case Library.duplicate_item(socket.assigns.current_item["id"]) do
      {:ok, _new_id} ->
        {:noreply, socket |> put_flash(:info, "item duplicado") |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "falha ao duplicar: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_item", _params, socket) do
    Library.delete_items([socket.assigns.current_item["id"]])
    {:noreply, socket |> put_flash(:info, "item apagado") |> patch_to(item: nil)}
  end

  ## Ações em massa

  def handle_event("bulk_process", _params, socket) do
    bulk_process(socket, panel_params(socket))
  end

  def handle_event("bulk_process_preset", %{"preset_id" => ""}, socket), do: {:noreply, socket}

  def handle_event("bulk_process_preset", %{"preset_id" => id}, socket) do
    case UserPresets.get(id) do
      nil ->
        {:noreply, socket}

      preset ->
        bulk_process(socket, Map.put(UserPresets.params(preset), "preset", preset["preset"]))
    end
  end

  def handle_event("bulk_move", %{"folder" => "__none__"}, socket), do: {:noreply, socket}

  def handle_event("bulk_move", %{"folder" => folder}, socket) do
    :ok = Library.move_items(MapSet.to_list(socket.assigns.selected), folder)

    {:noreply,
     socket |> assign(:selected, MapSet.new()) |> put_flash(:info, "itens movidos") |> reload()}
  end

  def handle_event("bulk_duplicate", _params, socket) do
    Enum.each(socket.assigns.selected, &Library.duplicate_item/1)

    {:noreply,
     socket |> assign(:selected, MapSet.new()) |> put_flash(:info, "itens duplicados") |> reload()}
  end

  def handle_event("bulk_delete", _params, socket) do
    Library.delete_items(MapSet.to_list(socket.assigns.selected))

    {:noreply,
     socket |> assign(:selected, MapSet.new()) |> put_flash(:info, "itens apagados") |> reload()}
  end

  ## Presets do usuário e concorrência

  def handle_event("save_preset", %{"name" => name}, socket) do
    attrs =
      socket
      |> panel_params()
      |> Map.merge(%{"name" => name, "preset" => socket.assigns.preset_id})

    case UserPresets.save(attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(user_presets: UserPresets.all(), preset_name: "")
         |> put_flash(:info, "preset salvo")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("apply_preset", %{"id" => id}, socket) do
    case UserPresets.get(id) do
      nil ->
        {:noreply, socket}

      p ->
        {:noreply,
         assign(socket,
           preset_id: p["preset"],
           halo: p["halo"],
           trail: p["trail"],
           detail: p["detail"],
           swap_sides: p["swap_sides"]
         )}
    end
  end

  def handle_event("delete_preset", %{"id" => id}, socket) do
    :ok = UserPresets.delete(id)
    {:noreply, assign(socket, :user_presets, UserPresets.all())}
  end

  def handle_event("set_concurrency", %{"concurrency" => n}, socket) do
    concurrency = String.to_integer(n)
    :ok = Jobs.set_concurrency(concurrency)
    {:noreply, assign(socket, :concurrency, concurrency)}
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex min-h-screen w-full gap-4 p-4">
        <aside class="w-64 shrink-0 space-y-5">
          <h1 class="text-xl font-semibold tracking-wide">
            camerex<span class="text-cx-orange">_</span>
          </h1>

          <div
            :if={@doctor_problems != []}
            id="doctor-banner"
            class="rounded-lg border border-cx-orange bg-cx-surface p-3 text-sm"
          >
            <p class="font-semibold text-cx-orange">dependências faltando</p>
            <div :for={{problem, i} <- Enum.with_index(@doctor_problems)} class="mt-2 space-y-1">
              <p>{problem.msg}</p>
              <code id={"doctor-fix-#{i}"} class="block rounded bg-cx-bg px-2 py-1">
                {problem.cmd}
              </code>
              <button
                type="button"
                class="text-cx-teal underline"
                phx-click={JS.dispatch("camerex:copy", to: "#doctor-fix-#{i}")}
              >
                copiar
              </button>
            </div>
          </div>

          <.folder_tree tree={@tree} current={@folder} root_count={@root_count} />

          <div class="space-y-1 text-sm">
            <button
              type="button"
              phx-click="open_modal"
              phx-value-modal="new_folder"
              class="w-full rounded border border-cx-border px-2 py-1.5 text-left text-cx-text-dim hover:text-cx-text"
            >
              + nova pasta
            </button>
            <button
              :if={@folder != "" and folder_deletable?(@tree, @items, @folder)}
              type="button"
              id="delete-folder"
              phx-click="delete_folder"
              phx-value-folder={@folder}
              data-confirm={"Remover a pasta vazia /#{@folder}?"}
              class="w-full rounded border border-cx-border px-2 py-1.5 text-left text-cx-text-dim"
            >
              remover esta pasta
            </button>
          </div>

          <form id="concurrency-form" phx-change="set_concurrency" class="text-sm">
            <label class="text-xs uppercase tracking-wide text-cx-text-dim">
              jobs em paralelo
            </label>
            <select
              name="concurrency"
              class="mt-1 w-full rounded border border-cx-border bg-cx-bg px-2 py-1.5"
            >
              <option :for={n <- 1..6} value={n} selected={n == @concurrency}>{n}</option>
            </select>
          </form>
        </aside>

        <main class="min-w-0 flex-1 space-y-4">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <.breadcrumb folder={@folder} />
            <div class="flex items-center gap-2 text-sm">
              <button
                type="button"
                id="import-button"
                phx-click="open_modal"
                phx-value-modal="import"
                class="neon-cta !mt-0"
              >
                importar pasta do disco
              </button>
              <button
                type="button"
                phx-click="select_all"
                class="rounded border border-cx-border px-3 py-1.5 text-cx-text-dim"
              >
                selecionar tudo
              </button>
            </div>
          </div>

          <.selection_bar
            :if={MapSet.size(@selected) > 0}
            count={MapSet.size(@selected)}
            user_presets={@user_presets}
            folders={Enum.map(@tree, & &1.path)}
          />

          <section
            id="gallery"
            class="grid grid-cols-[repeat(auto-fill,minmax(190px,1fr))] gap-3"
          >
            <.item_card
              :for={item <- @items}
              item={item}
              selected={MapSet.member?(@selected, item["id"])}
              progress={@progress[item["id"]]}
              active={@current_item != nil and @current_item["id"] == item["id"]}
            />
          </section>

          <div :if={@items == []} id="gallery-empty" class="neon-empty">
            <p class="neon-empty-title">nenhuma conversão nesta pasta</p>
            <p>solte uma mídia no painel ao lado ou importe uma pasta inteira do disco.</p>
            <button type="button" phx-click="open_modal" phx-value-modal="import" class="neon-cta">
              importar pasta do disco
            </button>
          </div>
        </main>

        <aside class="w-[400px] shrink-0 rounded-lg border border-cx-border bg-cx-surface p-4">
          <%= if @current_item && @reconvert_item == nil do %>
            <.detail_panel item={@current_item} progress={@progress[@current_item["id"]]} />
          <% else %>
            <.convert_panel
              uploads={@uploads}
              presets={@presets}
              preset_id={@preset_id}
              halo={@halo}
              trail={@trail}
              detail={@detail}
              swap_sides={@swap_sides}
              preview_data_url={@preview_data_url}
              preview_error={@preview_error}
              reconvert_item={@reconvert_item}
              user_presets={@user_presets}
              preset_name={@preset_name}
            />
          <% end %>
        </aside>
      </div>

      <%!-- sem phx-click no overlay: cliques DENTRO do painel borbulham até aqui
            e fechariam o modal; o phx-click-away do painel já cobre o clique fora --%>
      <div
        :if={@modal}
        id="modal-overlay"
        class="fixed inset-0 z-40 flex items-center justify-center bg-black/60"
        phx-window-keydown="close_modal"
        phx-key="escape"
      >
        <div
          class="w-full max-w-lg rounded-lg border border-cx-border bg-cx-surface p-5"
          phx-click-away="close_modal"
        >
          <div :if={@modal == :import} id="import-modal" class="space-y-3">
            <h2 class="text-lg font-semibold">importar pasta do disco</h2>
            <p class="text-sm text-cx-text-dim">
              as mídias são copiadas para a biblioteca em <strong>/{if @folder == "", do: "biblioteca", else: @folder}</strong>,
              espelhando as subpastas.
            </p>
            <form id="import-form" phx-submit="import_scan" class="flex gap-2">
              <input
                type="text"
                name="path"
                value={@import_path}
                placeholder="/Users/voce/Videos/forro"
                class="w-full rounded border border-cx-border bg-cx-bg px-2 py-1.5 text-sm"
              />
              <button
                type="submit"
                class="whitespace-nowrap rounded border border-cx-teal px-3 py-1.5 text-sm text-cx-teal"
              >
                escanear
              </button>
            </form>

            <div :if={@import_scan} id="import-scan-result" class="text-sm">
              <%= case @import_scan do %>
                <% {:ok, %{media: media, total_bytes: bytes}} -> %>
                  <p>
                    <strong>{length(media)}</strong>
                    mídia(s) encontrada(s) · {Float.round(bytes / 1_048_576, 1)} MB
                  </p>
                  <button
                    :if={media != []}
                    type="button"
                    id="import-run"
                    phx-click="import_run"
                    class="neon-cta"
                  >
                    importar tudo
                  </button>
                <% {:error, msg} -> %>
                  <p class="text-cx-orange">{msg}</p>
              <% end %>
            </div>
          </div>

          <div :if={@modal == :new_folder} id="new-folder-modal" class="space-y-3">
            <h2 class="text-lg font-semibold">nova pasta</h2>
            <p :if={@folder != ""} class="text-sm text-cx-text-dim">
              dentro de /{@folder}
            </p>
            <form id="new-folder-form" phx-submit="create_folder" class="flex gap-2">
              <input
                type="text"
                name="name"
                value={@new_folder_name}
                placeholder="nome da pasta…"
                class="w-full rounded border border-cx-border bg-cx-bg px-2 py-1.5 text-sm"
              />
              <button
                type="submit"
                class="whitespace-nowrap rounded border border-cx-teal px-3 py-1.5 text-sm text-cx-teal"
              >
                criar
              </button>
            </form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp folder_deletable?(tree, items, folder) do
    items == [] and not Enum.any?(tree, &String.starts_with?(&1.path, folder <> "/"))
  end

  ## Internas — estado

  defp reload(socket) do
    %{items: items, tree: tree, root_count: root_count} =
      Library.snapshot(socket.assigns.folder)

    socket
    |> assign(
      items: items,
      tree: tree,
      root_count: root_count,
      selected: MapSet.intersection(socket.assigns.selected, MapSet.new(items, & &1["id"]))
    )
    |> subscribe_processing(items)
  end

  defp assign_current_item(socket, nil), do: assign(socket, :current_item, nil)

  defp assign_current_item(socket, id) do
    case Workspace.manifest(id) do
      {:ok, manifest} -> assign(socket, :current_item, manifest)
      {:error, :not_found} -> assign(socket, :current_item, nil)
    end
  end

  defp refresh_current_item(socket) do
    case socket.assigns.current_item do
      nil -> socket
      %{"id" => id} -> assign_current_item(socket, id)
    end
  end

  defp patch_to(socket, overrides) do
    folder = Keyword.get(overrides, :folder, socket.assigns.folder)
    item = Keyword.get(overrides, :item, socket.assigns.current_item["id"])

    params =
      [folder: folder, item: item]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    push_patch(socket, to: ~p"/?#{params}")
  end

  defp subscribe_processing(socket, items) do
    subscribed = socket.assigns.subscribed_jobs

    new_ids =
      items
      |> Enum.filter(&(&1["status"] == "processing"))
      |> Enum.map(& &1["id"])
      |> MapSet.new()
      |> MapSet.difference(subscribed)

    Enum.each(new_ids, &Jobs.subscribe/1)
    assign(socket, subscribed_jobs: MapSet.union(subscribed, new_ids))
  end

  ## Internas — conversão

  defp convert_upload(socket) do
    folder = socket.assigns.folder

    ids =
      consume_uploaded_entries(socket, :media, fn %{path: path}, entry ->
        {:ok, _id} =
          Workspace.create_item(
            path,
            entry.client_name,
            media_type(entry.client_name),
            socket.assigns.preset_id,
            panel_params_for(socket, media_type(entry.client_name)),
            folder: folder
          )
      end)

    case ids do
      [] ->
        {:noreply, put_flash(socket, :error, "Escolha uma foto ou vídeo para converter.")}

      ids ->
        Enum.each(ids, &Jobs.enqueue/1)
        {:noreply, socket |> assign(preview_data_url: nil) |> reload()}
    end
  end

  defp reprocess_item(socket, item) do
    params = Map.put(panel_params(socket), "preset", socket.assigns.preset_id)
    Library.process_items([item["id"]], params)

    {:noreply,
     socket
     |> assign(:reconvert_item, nil)
     |> put_flash(:info, "reprocessando #{item["original_filename"]}")
     |> reload()
     |> refresh_current_item()}
  end

  defp do_preview_frame(socket) do
    results =
      consume_uploaded_entries(socket, :media, fn %{path: path}, _entry ->
        {:postpone, FramePreview.data_url(path, preview_opts(socket))}
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

  defp assign_controls(socket, params) do
    assign(socket,
      halo: parse_slider(params["halo"], socket.assigns.halo),
      trail: parse_slider(params["trail"], socket.assigns.trail),
      detail: parse_slider(params["detail"], socket.assigns.detail),
      swap_sides: params["swap_sides"] == "true"
    )
  end

  defp apply_item_params(socket, %{"params" => params} = item) when is_map(params) do
    assign(socket,
      preset_id: item["preset"] || socket.assigns.preset_id,
      halo: params["halo"] || socket.assigns.halo,
      trail: params["trail"] || socket.assigns.trail,
      detail: params["detail"] || socket.assigns.detail,
      swap_sides: params["swap_sides"] || false
    )
  end

  defp apply_item_params(socket, _item), do: socket

  defp parse_slider(nil, fallback), do: fallback

  defp parse_slider(value, fallback) do
    case Float.parse(value) do
      {f, _rest} -> f
      :error -> fallback
    end
  end

  defp panel_params(socket), do: panel_params_for(socket, :photo)

  defp panel_params_for(socket, type) do
    %{
      "halo" => socket.assigns.halo,
      "trail" => socket.assigns.trail,
      "detail" => socket.assigns.detail,
      "swap_sides" => socket.assigns.swap_sides,
      "model" => default_model(type)
    }
  end

  defp default_panel_params(socket), do: panel_params(socket)

  defp bulk_process(socket, params) do
    params = Map.put_new(params, "preset", socket.assigns.preset_id)

    %{enqueued: n, skipped: skipped} =
      Library.process_items(MapSet.to_list(socket.assigns.selected), params)

    flash =
      if skipped > 0,
        do: "#{n} item(ns) na fila (#{skipped} pulado(s) — já em processamento)",
        else: "#{n} item(ns) na fila"

    {:noreply, socket |> assign(:selected, MapSet.new()) |> put_flash(:info, flash) |> reload()}
  end

  defp media_type(filename) do
    if Path.extname(String.downcase(filename)) in @video_exts, do: :video, else: :photo
  end

  # u2net para tudo (gate da fase 0 v1); u2netp fica para a prévia
  defp default_model(_type), do: "u2net"

  defp duotone?(preset_id), do: match?(%{mode: :duotone}, Palette.get(preset_id))

  ## Internas — prévia

  defp preview_opts(socket) do
    [
      preset: socket.assigns.preset_id,
      halo: socket.assigns.halo,
      detail: socket.assigns.detail,
      swap_sides: socket.assigns.swap_sides,
      model: "u2netp"
    ]
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)

  ## Doctor

  defp doctor_module, do: Application.get_env(:camerex, :doctor, Camerex.Doctor)

  defp doctor_problems(%{ffmpeg: ffmpeg, models: models}) do
    for {result, cmd} <- [{ffmpeg, "brew install ffmpeg"}, {models, "mix camerex.setup"}],
        {:error, msg} <- [result] do
      %{msg: msg, cmd: cmd}
    end
  end
end
