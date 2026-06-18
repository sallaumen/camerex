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

  alias Camerex.{
    Calibration,
    Jobs,
    Library,
    RenderParams,
    Settings,
    SystemStats,
    UserPresets,
    Workspace
  }

  alias Camerex.Library.Import, as: LibraryImport
  alias Camerex.Parser.Layers
  alias Camerex.Pipeline.Video

  @video_exts ~w(.mp4 .mov .m4v .webm)
  # tick do mini-dashboard de performance (CPU/RAM); cache do prompt à parte,
  # 2s é responsivo sem floodar o socket
  @perf_interval 2_000

  ## Mount / params

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Jobs.subscribe()
      Process.send_after(self(), :perf_tick, @perf_interval)
    end

    socket =
      socket
      |> assign(
        folder: "",
        items: [],
        visible_items: [],
        query: "",
        status_filter: "",
        tree: [],
        root_count: 0,
        selected: MapSet.new(),
        current_item: nil,
        reconvert_item: nil,
        convert_open: false,
        modal: nil,
        import_path: "",
        import_scan: nil,
        new_folder_name: "",
        perf: SystemStats.snapshot(),
        jobs_summary: jobs_summary(),
        frame_concurrency: Video.frame_concurrency(),
        colors_json: "",
        colors_json_error: nil,
        render_params: RenderParams.default(),
        preset_name: "",
        user_presets: UserPresets.all(),
        concurrency: Settings.get("concurrency", 3),
        calib: nil,
        calib_url: nil,
        calib_error: nil,
        calib_ref: nil,
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
        auto_upload: true,
        progress: &handle_progress/3
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
    {:noreply,
     socket |> reload() |> refresh_current_item() |> assign(:jobs_summary, jobs_summary())}
  end

  def handle_info({:job_progress, id, prog}, socket) do
    {:noreply, assign(socket, progress: Map.put(socket.assigns.progress, id, prog))}
  end

  ## Calibragem ao vivo (Tasks async → estas mensagens)

  def handle_info({:calib_ready, {:ok, session}}, socket) do
    {:noreply,
     socket |> assign(:calib, session) |> suggest_layer_colors(session) |> rerender_calibration()}
  end

  def handle_info({:calib_ready, {:error, reason}}, socket) do
    {:noreply, assign(socket, calib: nil, calib_error: error_message(reason))}
  end

  # só o render mais recente vale; refs antigas são descartadas em silêncio
  def handle_info({:calib_render, ref, result}, %{assigns: %{calib_ref: ref}} = socket) do
    case result do
      {:ok, data_url} -> {:noreply, assign(socket, calib_url: data_url, calib_error: nil)}
      {:error, reason} -> {:noreply, assign(socket, :calib_error, error_message(reason))}
    end
  end

  def handle_info({:calib_render, _stale_ref, _result}, socket), do: {:noreply, socket}

  # tick do mini-dashboard: re-amostra CPU/RAM/BEAM + agregado de jobs (pega o
  # progresso de jobs em QUALQUER pasta, não só os do filtro atual) e reagenda
  def handle_info(:perf_tick, socket) do
    Process.send_after(self(), :perf_tick, @perf_interval)
    {:noreply, assign(socket, perf: SystemStats.snapshot(), jobs_summary: jobs_summary())}
  end

  ## Navegação e seleção

  @impl true
  def handle_event("select_folder", %{"folder" => folder}, socket) do
    {:noreply, patch_to(socket, folder: folder, item: nil)}
  end

  def handle_event("open_item", %{"id" => id}, socket) do
    # abrir um item sempre mostra o detalhe DELE: sai de qualquer modo de
    # conversão/reprocesso/calibragem (senão o painel direito fica preso no
    # item anterior enquanto se importa/reprocessa)
    {:noreply,
     socket
     |> assign(reconvert_item: nil, convert_open: false)
     |> clear_calibration()
     |> patch_to(item: id)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply,
     socket |> assign(:reconvert_item, nil) |> clear_calibration() |> patch_to(item: nil)}
  end

  # abre o painel de nova conversão (sai do detalhe e de qualquer reprocesso)
  def handle_event("open_convert", _params, socket) do
    {:noreply,
     socket
     |> assign(convert_open: true, reconvert_item: nil)
     |> clear_calibration()
     |> patch_to(item: nil)}
  end

  # fecha o painel de conversão/reprocesso → volta ao placeholder (ou ao detalhe
  # do item, se houver um selecionado)
  def handle_event("close_convert", _params, socket) do
    {:noreply, socket |> assign(convert_open: false, reconvert_item: nil) |> clear_calibration()}
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
    ids = MapSet.new(socket.assigns.visible_items, & &1["id"])
    {:noreply, assign(socket, :selected, ids)}
  end

  ## Busca e filtro

  def handle_event("filter", %{"q" => query, "status" => status}, socket) do
    {:noreply, socket |> assign(query: query, status_filter: status) |> assign_visible()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, socket |> assign(query: "", status_filter: "") |> assign_visible()}
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

  # abre a modal de cores em lote já preenchida com o JSON das cores atuais
  def handle_event("open_modal", %{"modal" => "colors_json"}, socket) do
    {:noreply,
     assign(socket,
       modal: :colors_json,
       colors_json: colors_to_json(socket.assigns.render_params.layer_colors),
       colors_json_error: nil
     )}
  end

  # aplica o JSON colado: parse → atualiza as cores por parte (e a prévia). Erro
  # mantém o texto digitado e mostra a mensagem.
  def handle_event("apply_colors_json", %{"json" => json}, socket) do
    case parse_colors_json(json) do
      {:ok, colors} ->
        {:noreply,
         socket
         |> put_render_params(layer_colors: colors)
         |> assign(modal: nil, colors_json_error: nil)
         |> rerender_calibration()}

      {:error, msg} ->
        {:noreply, assign(socket, colors_json: json, colors_json_error: msg)}
    end
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

  def handle_event("validate", params, socket) do
    {:noreply, socket |> assign_controls(params) |> rerender_calibration()}
  end

  def handle_event("convert", params, socket) do
    socket = assign_controls(socket, params)

    case socket.assigns.reconvert_item do
      nil -> convert_upload(socket)
      item -> reprocess_item(socket, item)
    end
  end

  # importa sem processar: cria o item (status "new") e NÃO enfileira job —
  # a pessoa clica "Processar" no detalhe quando quiser
  def handle_event("import_only", _params, socket) do
    case import_uploads(socket, convert?: false) do
      [] ->
        {:noreply, put_flash(socket, :error, "Escolha uma foto ou vídeo para importar.")}

      _ids ->
        {:noreply,
         socket
         |> assign(:convert_open, false)
         |> clear_calibration()
         |> put_flash(:info, "importado sem processar — use “Processar” quando quiser")
         |> reload()}
    end
  end

  ## Reprocesso in-place

  def handle_event("reconvert_start", _params, socket) do
    item = socket.assigns.current_item

    socket =
      socket
      |> assign(:reconvert_item, item)
      |> apply_item_params(item)
      |> begin_calibration(item)

    {:noreply, socket}
  end

  def handle_event("reconvert_cancel", _params, socket) do
    {:noreply, socket |> assign(:reconvert_item, nil) |> clear_calibration()}
  end

  def handle_event("retry_item", _params, socket) do
    item = socket.assigns.current_item
    params = item["params"] || panel_params(socket)
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
        bulk_process(socket, UserPresets.params(preset))
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

  ## Aplicação direta da calibragem (atalhos do modo ao vivo)

  def handle_event("apply_folder", _params, socket) do
    apply_calibration_to(socket, Enum.map(socket.assigns.items, & &1["id"]))
  end

  def handle_event("apply_selection", _params, socket) do
    apply_calibration_to(socket, MapSet.to_list(socket.assigns.selected))
  end

  ## Presets do usuário e concorrência

  def handle_event("save_preset", %{"name" => name}, socket) do
    attrs =
      socket
      |> panel_params()
      |> Map.put("name", name)

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

      preset ->
        # restaura pela MESMA trilha do reprocesso (apply_item_params), então o
        # preset traz de volta TODOS os controles — não só halo/trail/detail
        socket =
          socket
          |> apply_item_params(%{"params" => UserPresets.params(preset)})
          |> rerender_calibration()

        {:noreply, socket}
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

  # threads/frame do vídeo: persiste (clamp em Video) e ecoa o valor aplicado;
  # entrada inválida mantém o atual
  def handle_event("set_frame_concurrency", %{"frame_concurrency" => n}, socket) do
    applied =
      case Integer.parse(n) do
        {i, _} -> Video.set_frame_concurrency(i)
        :error -> socket.assigns.frame_concurrency
      end

    {:noreply, assign(socket, :frame_concurrency, applied)}
  end

  # Esc fecha a camada mais ao topo: modal > reprocesso > painel de detalhe
  def handle_event("escape_pressed", _params, socket) do
    cond do
      socket.assigns.modal != nil ->
        {:noreply, assign(socket, :modal, nil)}

      socket.assigns.reconvert_item != nil ->
        {:noreply, socket |> assign(:reconvert_item, nil) |> clear_calibration()}

      socket.assigns.convert_open ->
        {:noreply, socket |> assign(:convert_open, false) |> clear_calibration()}

      socket.assigns.current_item != nil ->
        {:noreply, patch_to(socket, item: nil)}

      true ->
        {:noreply, socket}
    end
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.perf_dashboard perf={@perf} frame_concurrency={@frame_concurrency} />
      <div
        id="library-root"
        class="flex min-h-screen w-full gap-4 p-4"
        phx-window-keydown="escape_pressed"
        phx-key="escape"
      >
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
            <div class="flex items-center gap-3">
              <.breadcrumb folder={@folder} />
              <.jobs_indicator summary={@jobs_summary} />
            </div>
            <div class="flex items-center gap-2 text-sm">
              <button
                type="button"
                id="new-conversion"
                phx-click="open_convert"
                class="neon-cta !mt-0"
              >
                + nova conversão
              </button>
              <button
                type="button"
                id="import-button"
                phx-click="open_modal"
                phx-value-modal="import"
                class="rounded border border-cx-border px-3 py-1.5 text-cx-text-dim hover:text-cx-text focus-visible:ring-2 focus-visible:ring-cx-teal"
              >
                importar pasta
              </button>
              <button
                :if={@visible_items != []}
                type="button"
                phx-click="select_all"
                class="rounded border border-cx-border px-3 py-1.5 text-cx-text-dim hover:text-cx-text focus-visible:ring-2 focus-visible:ring-cx-teal"
              >
                selecionar tudo
              </button>
              <a
                :if={Enum.any?(@items, &(&1["status"] == "done"))}
                id="export-folder"
                href={~p"/export/folder?folder=#{@folder}"}
                download
                class="rounded border border-cx-border px-3 py-1.5 text-cx-text-dim hover:text-cx-text focus-visible:ring-2 focus-visible:ring-cx-teal"
              >
                baixar tudo (.zip)
              </a>
            </div>
          </div>

          <%!-- destaque: detalhe (antes|depois grande) ou conversão, em cima;
                a biblioteca (galeria) fica logo abaixo, largura cheia --%>
          <section
            :if={@current_item || @reconvert_item || @convert_open}
            id="focus-zone"
            class="rounded-lg border border-cx-border bg-cx-surface p-4"
          >
            <%= cond do %>
              <% @current_item && @reconvert_item == nil -> %>
                <.detail_panel item={@current_item} progress={@progress[@current_item["id"]]} />
              <% true -> %>
                <.convert_panel
                  uploads={@uploads}
                  halo={@render_params.halo}
                  bloom={@render_params.bloom}
                  layer_colors={@render_params.layer_colors}
                  detect_object={@render_params.detect_object}
                  detect_aerial={@render_params.detect_aerial}
                  aerial_color={@render_params.aerial_color}
                  bg_opacity={@render_params.bg_opacity}
                  transparent_bg={@render_params.transparent_bg}
                  fill={@render_params.fill}
                  fill_color={@render_params.fill_color}
                  fill_texture={@render_params.fill_texture}
                  floor={@render_params.floor}
                  glow={@render_params.glow}
                  spread={@render_params.spread}
                  trail={@render_params.trail}
                  detail={@render_params.detail}
                  calib={@calib}
                  calib_url={@calib_url}
                  calib_error={@calib_error}
                  folder_count={length(@items)}
                  selected_count={MapSet.size(@selected)}
                  reconvert_item={@reconvert_item}
                  user_presets={@user_presets}
                  preset_name={@preset_name}
                />
            <% end %>
          </section>

          <.filter_bar
            :if={@items != []}
            query={@query}
            status={@status_filter}
            count={length(@visible_items)}
            total={length(@items)}
          />

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
              :for={item <- @visible_items}
              item={item}
              selected={MapSet.member?(@selected, item["id"])}
              progress={@progress[item["id"]]}
              active={@current_item != nil and @current_item["id"] == item["id"]}
            />
          </section>

          <div :if={@items == []} id="gallery-empty" class="neon-empty">
            <p class="neon-empty-title">nenhuma conversão nesta pasta</p>
            <p>comece uma nova conversão ou importe uma pasta inteira do disco.</p>
            <div class="mt-2 flex flex-wrap items-center justify-center gap-2">
              <button type="button" phx-click="open_convert" class="neon-cta">
                + nova conversão
              </button>
              <button
                type="button"
                phx-click="open_modal"
                phx-value-modal="import"
                class="rounded border border-cx-border px-3 py-1.5 text-cx-text-dim hover:text-cx-text focus-visible:ring-2 focus-visible:ring-cx-teal"
              >
                importar pasta
              </button>
            </div>
          </div>

          <div :if={@items != [] and @visible_items == []} id="filter-empty" class="neon-empty">
            <p class="neon-empty-title">nada bate com os filtros</p>
            <button type="button" phx-click="clear_filters" class="neon-cta">
              limpar filtros
            </button>
          </div>
        </main>
      </div>

      <%!-- sem phx-click no overlay: cliques DENTRO do painel borbulham até aqui
            e fechariam o modal; o phx-click-away do painel já cobre o clique fora.
            Esc é tratado no handler global do #library-root (modal tem prioridade) --%>
      <div
        :if={@modal}
        id="modal-overlay"
        class="fixed inset-0 z-40 flex items-center justify-center bg-black/60"
      >
        <div
          class="w-full max-w-lg rounded-lg border border-cx-border bg-cx-surface p-5"
          phx-click-away="close_modal"
        >
          <div
            :if={@modal == :import}
            id="import-modal"
            role="dialog"
            aria-modal="true"
            aria-labelledby="import-modal-title"
            class="space-y-3"
          >
            <h2 id="import-modal-title" class="text-lg font-semibold">importar pasta do disco</h2>
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
                autocomplete="off"
                phx-mounted={JS.focus()}
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

          <div
            :if={@modal == :new_folder}
            id="new-folder-modal"
            role="dialog"
            aria-modal="true"
            aria-labelledby="new-folder-modal-title"
            class="space-y-3"
          >
            <h2 id="new-folder-modal-title" class="text-lg font-semibold">nova pasta</h2>
            <p :if={@folder != ""} class="text-sm text-cx-text-dim">
              dentro de /{@folder}
            </p>
            <form id="new-folder-form" phx-submit="create_folder" class="flex gap-2">
              <input
                type="text"
                name="name"
                value={@new_folder_name}
                placeholder="nome da pasta…"
                autocomplete="off"
                phx-mounted={JS.focus()}
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

          <div
            :if={@modal == :colors_json}
            id="colors-json-modal"
            role="dialog"
            aria-modal="true"
            aria-labelledby="colors-json-title"
            class="space-y-3"
          >
            <h2 id="colors-json-title" class="text-lg font-semibold">cores por parte (JSON)</h2>
            <p class="text-sm text-cx-text-dim">
              cole as cores em hex (<code>"#RRGGBB"</code>) ou <code>[r, g, b]</code>. partes ausentes
              ficam no padrão; chaves desconhecidas são ignoradas.
            </p>
            <form id="colors-json-form" phx-submit="apply_colors_json" class="space-y-2">
              <textarea
                name="json"
                rows="12"
                spellcheck="false"
                phx-mounted={JS.focus()}
                class="w-full rounded border border-cx-border bg-cx-bg p-2 font-mono text-sm text-cx-text"
              >{@colors_json}</textarea>
              <p
                :if={@colors_json_error}
                id="colors-json-error"
                role="alert"
                class="text-sm text-cx-orange"
              >
                {@colors_json_error}
              </p>
              <div class="flex items-center gap-2">
                <button type="submit" class="rounded bg-cx-teal px-4 py-2 font-medium text-cx-bg">
                  aplicar cores
                </button>
                <button
                  type="button"
                  phx-click="close_modal"
                  class="rounded border border-cx-border px-3 py-1.5 text-sm text-cx-text-dim hover:text-cx-text"
                >
                  cancelar
                </button>
              </div>
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
    |> assign_visible()
    |> subscribe_processing(items)
  end

  defp assign_visible(socket) do
    %{items: items, query: query, status_filter: status} = socket.assigns
    assign(socket, :visible_items, filter_items(items, query, status))
  end

  defp filter_items(items, query, status) do
    needle = fold(query)

    Enum.filter(items, fn item ->
      (status == "" or item["status"] == status) and
        (needle == "" or String.contains?(fold(item["original_filename"] || ""), needle))
    end)
  end

  # busca insensível a acento: "forro" encontra "Forró-Show.png"
  defp fold(text) do
    text |> String.downcase() |> String.normalize(:nfd) |> String.replace(~r/\p{Mn}/u, "")
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
      |> MapSet.new(& &1["id"])
      |> MapSet.difference(subscribed)

    Enum.each(new_ids, &Jobs.subscribe/1)
    assign(socket, subscribed_jobs: MapSet.union(subscribed, new_ids))
  end

  # agregado do pool pro indicador global: contagens + soma de frames + maior
  # ETA entre os jobs rodando (de QUALQUER pasta — vem do Jobs, não do disco)
  defp jobs_summary do
    %{running: running, queue: queue} = Jobs.state()
    progs = running |> Enum.map(& &1.progress) |> Enum.filter(&(&1.total > 0))

    %{
      processing: length(running),
      queued: length(queue),
      done: progs |> Enum.map(& &1.done) |> Enum.sum(),
      total: progs |> Enum.map(& &1.total) |> Enum.sum(),
      eta_s: progs |> Enum.map(& &1.eta_s) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
    }
  end

  ## Internas — conversão

  defp convert_upload(socket) do
    case import_uploads(socket, convert?: true) do
      [] ->
        {:noreply, put_flash(socket, :error, "Escolha uma foto ou vídeo para converter.")}

      ids ->
        Enum.each(ids, &Jobs.enqueue/1)
        {:noreply, socket |> assign(:convert_open, false) |> clear_calibration() |> reload()}
    end
  end

  # consome os uploads e cria os itens (sem enfileirar) — base comum de
  # "Converter" e "Só importar". Sem params (convert?: false) → item "new" (só
  # importa, igual à importação de pasta); com params → "queued". create_item
  # devolve {:ok, id}, que o consume_uploaded_entries desembrulha pro id.
  defp import_uploads(socket, convert?: convert?) do
    folder = socket.assigns.folder

    consume_uploaded_entries(socket, :media, fn %{path: path}, entry ->
      type = media_type(entry.client_name)
      params = if convert?, do: panel_params_for(socket, type), else: nil
      Workspace.create_item(path, entry.client_name, type, params, folder: folder)
    end)
  end

  defp reprocess_item(socket, item) do
    params = panel_params(socket)
    Library.process_items([item["id"]], params)

    {:noreply,
     socket
     |> assign(:reconvert_item, nil)
     |> clear_calibration()
     |> put_flash(:info, "reprocessando #{item["original_filename"]}")
     |> reload()
     |> refresh_current_item()}
  end

  ## Internas — calibragem ao vivo

  defp begin_calibration(socket, item) do
    lv = self()
    path = Workspace.item_path(item["id"], item["original_file"])
    type = item["type"]

    {:ok, _pid} = Task.start(fn -> send(lv, {:calib_ready, safe_prepare(path, type)}) end)
    assign(socket, calib: :preparing, calib_url: nil, calib_error: nil, calib_ref: nil)
  end

  # roda dentro da Task desvinculada: erro vira mensagem, nunca silêncio
  defp safe_prepare(path, type) do
    Calibration.prepare_file(path, type)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp rerender_calibration(%{assigns: %{calib: %{} = session}} = socket) do
    lv = self()
    ref = make_ref()
    params = panel_params(socket)

    {:ok, _pid} =
      Task.start(fn -> send(lv, {:calib_render, ref, safe_render(session, params)}) end)

    assign(socket, :calib_ref, ref)
  end

  defp rerender_calibration(socket), do: socket

  # upload novo: pré-preenche os pickers com as cores detectadas das partes
  # (coerentes com a roupa). No reprocesso de um item, as cores salvas do
  # manifest (apply_item_params) mandam — não sobrescreve.
  defp suggest_layer_colors(socket, %{labels: labels, rgb: rgb}) when labels != nil do
    if socket.assigns.reconvert_item == nil do
      put_render_params(socket, layer_colors: Layers.suggest_colors(rgb, labels))
    else
      socket
    end
  end

  defp suggest_layer_colors(socket, _session), do: socket

  defp safe_render(session, params) do
    Calibration.render(session, params)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp clear_calibration(socket) do
    assign(socket, calib: nil, calib_url: nil, calib_error: nil, calib_ref: nil)
  end

  # upload concluído (auto_upload) → abre a calibragem ao vivo sem consumir
  # a entry: {:postpone, _} espia o tmp do upload e o deixa vivo para o submit
  defp handle_progress(:media, entry, socket) do
    if entry.done? do
      {:noreply, begin_upload_calibration(socket)}
    else
      {:noreply, socket}
    end
  end

  defp begin_upload_calibration(socket) do
    sources =
      consume_uploaded_entries(socket, :media, fn %{path: path}, entry ->
        {:postpone, {path, media_type(entry.client_name)}}
      end)

    case sources do
      [{path, type}] ->
        lv = self()
        kind = if type == :video, do: "video", else: "photo"
        {:ok, _pid} = Task.start(fn -> send(lv, {:calib_ready, safe_prepare(path, kind)}) end)
        assign(socket, calib: :preparing, calib_url: nil, calib_error: nil, calib_ref: nil)

      _none ->
        socket
    end
  end

  defp assign_controls(socket, params) do
    assign(socket, :render_params, RenderParams.from_form(params, socket.assigns.render_params))
  end

  defp apply_item_params(socket, %{"params" => params} = item) when is_map(params) do
    assign(socket, :render_params, RenderParams.from_manifest(item, socket.assigns.render_params))
  end

  defp apply_item_params(socket, _item), do: socket

  # escritas pontuais de campos do %RenderParams{} a partir dos handlers
  defp put_render_params(socket, fields) do
    assign(socket, :render_params, struct(socket.assigns.render_params, fields))
  end

  defp hex_to_rgb("#" <> <<r::binary-2, g::binary-2, b::binary-2>>) do
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  defp panel_params(socket), do: panel_params_for(socket, :photo)

  defp panel_params_for(socket, type) do
    socket.assigns.render_params
    |> RenderParams.to_manifest()
    |> Map.put("model", default_model(type))
  end

  # cores atuais -> JSON hex legível e ORDENADO pelos grupos (pra editar na modal)
  defp colors_to_json(colors) do
    body =
      Enum.map_join(Layers.groups(), ",\n", fn %{key: key, default: default} ->
        hex = colors |> Map.get(key, default) |> Layers.hex()
        ~s(  "#{key}": "#{hex}")
      end)

    "{\n" <> body <> "\n}"
  end

  # JSON colado -> %{atom => {r,g,b}} mesclado sobre os defaults. Aceita "#RRGGBB"
  # ou [r,g,b]; ignora partes desconhecidas; cor malformada vira erro legível.
  defp parse_colors_json(json) do
    case JSON.decode(json) do
      {:ok, map} when is_map(map) -> build_layer_colors(map)
      {:ok, _other} -> {:error, ~s(o JSON precisa ser um objeto, ex: {"roupa": "#2BC4B2"})}
      {:error, _} -> {:error, "JSON inválido — confira aspas, vírgulas e chaves { }"}
    end
  end

  defp build_layer_colors(map) do
    known = Map.new(Layers.groups(), fn g -> {Atom.to_string(g.key), g.key} end)

    Enum.reduce_while(map, {:ok, Layers.default_colors()}, fn {raw_key, raw_val}, {:ok, acc} ->
      case {Map.get(known, raw_key), json_color(raw_val)} do
        {nil, _} ->
          {:cont, {:ok, acc}}

        {key, {:ok, rgb}} ->
          {:cont, {:ok, Map.put(acc, key, rgb)}}

        {_key, :error} ->
          {:halt, {:error, ~s(cor inválida em "#{raw_key}": use "#RRGGBB" ou [r,g,b])}}
      end
    end)
  end

  defp json_color("#" <> _ = hex) do
    if String.match?(hex, ~r/^#[0-9a-fA-F]{6}$/), do: {:ok, hex_to_rgb(hex)}, else: :error
  end

  defp json_color([r, g, b])
       when is_integer(r) and is_integer(g) and is_integer(b) and
              r in 0..255 and g in 0..255 and b in 0..255 do
    {:ok, {r, g, b}}
  end

  defp json_color(_), do: :error

  defp bulk_process(socket, params) do
    result = Library.process_items(MapSet.to_list(socket.assigns.selected), params)

    {:noreply,
     socket
     |> assign(:selected, MapSet.new())
     |> put_flash(:info, queue_flash(result))
     |> reload()}
  end

  defp apply_calibration_to(socket, ids) do
    params = panel_params(socket)
    result = Library.process_items(ids, params)

    {:noreply,
     socket |> put_flash(:info, queue_flash(result)) |> reload() |> refresh_current_item()}
  end

  defp queue_flash(%{enqueued: n, skipped: 0}), do: "#{n} item(ns) na fila"

  defp queue_flash(%{enqueued: n, skipped: skipped}),
    do: "#{n} item(ns) na fila (#{skipped} pulado(s) — já em processamento)"

  defp media_type(filename) do
    if Path.extname(String.downcase(filename)) in @video_exts, do: :video, else: :photo
  end

  # u2net para tudo (gate da fase 0 v1); u2netp fica para a prévia
  defp default_model(_type), do: "u2net"

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
