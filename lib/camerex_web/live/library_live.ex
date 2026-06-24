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
    ColorJSON,
    Doctor,
    Jobs,
    Library,
    RenderParams,
    Settings,
    SystemStats,
    UserPresets,
    Workspace
  }

  alias Camerex.Library.Import, as: LibraryImport
  alias Camerex.Parser.{LayerRegistry, Layers}
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
        jobs_summary: Jobs.summary(),
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
        eyedrop_armed: false,
        # acordeão de camadas extras: 1ª tag aberta, demais colapsadas
        collapsed_layer_tags: LayerRegistry.tags() |> Enum.drop(1) |> MapSet.new(),
        progress: %{},
        subscribed_jobs: MapSet.new(),
        doctor_problems: Doctor.problems(doctor_module().check())
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
     socket |> reload() |> refresh_current_item() |> assign(:jobs_summary, Jobs.summary())}
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
    {:noreply, assign(socket, perf: SystemStats.snapshot(), jobs_summary: Jobs.summary())}
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
       colors_json: ColorJSON.to_json(socket.assigns.render_params.layer_colors),
       colors_json_error: nil
     )}
  end

  # aplica o JSON colado: parse → atualiza as cores por parte (e a prévia). Erro
  # mantém o texto digitado e mostra a mensagem.
  def handle_event("apply_colors_json", %{"json" => json}, socket) do
    case ColorJSON.parse(json) do
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

  # conta-gotas do cabelo: arma/desarma o modo de clique na prévia
  def handle_event("toggle_eyedrop", _params, socket) do
    {:noreply, assign(socket, :eyedrop_armed, not socket.assigns.eyedrop_armed)}
  end

  # colapsa/expande um grupo (tag) do acordeão de camadas extras
  def handle_event("toggle_layer_group", %{"tag" => tag}, socket) do
    collapsed = socket.assigns.collapsed_layer_tags

    collapsed =
      if MapSet.member?(collapsed, tag),
        do: MapSet.delete(collapsed, tag),
        else: MapSet.put(collapsed, tag)

    {:noreply, assign(socket, :collapsed_layer_tags, collapsed)}
  end

  # clique armado na prévia: amostra a cor do cabelo no ponto e re-renderiza
  def handle_event("eyedrop_hair", %{"xf" => xf, "yf" => yf}, socket) do
    case socket.assigns.calib do
      %{} = calib when is_map(calib) ->
        case Calibration.sample_hair_color(calib, {xf, yf}) do
          {_, _, _} = cor ->
            {:noreply,
             socket
             |> put_render_params(hair_color: cor)
             |> assign(:eyedrop_armed, false)
             |> rerender_calibration()
             |> put_flash(:info, "cor do cabelo capturada")}

          nil ->
            {:noreply, put_flash(socket, :error, "clique no cabelo, não no fundo")}
        end

      _ ->
        {:noreply, socket}
    end
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

  # editar direto da galeria/herói: junta "abrir" + "reprocessar" num passo só —
  # carrega o item, entra no painel de reprocesso (com prévia ao vivo) e fixa o ?item
  def handle_event("edit_item", %{"id" => id}, socket) do
    case Workspace.manifest(id) do
      {:ok, item} ->
        {:noreply,
         socket
         |> assign(current_item: item, reconvert_item: item, convert_open: false)
         |> apply_item_params(item)
         |> begin_calibration(item)
         |> patch_to(item: id)}

      {:error, :not_found} ->
        {:noreply, socket}
    end
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

  def handle_event("toggle_queue_pause", _params, socket) do
    :ok = Jobs.set_paused(not socket.assigns.jobs_summary.paused)
    {:noreply, assign(socket, :jobs_summary, Jobs.summary())}
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
        class="flex min-h-screen w-full flex-col gap-4 p-4 pb-12 lg:h-screen lg:flex-row lg:overflow-hidden"
        phx-window-keydown="escape_pressed"
        phx-key="escape"
      >
        <aside class="w-full space-y-5 lg:w-64 lg:shrink-0 lg:overflow-y-auto lg:pb-10">
          <h1 class="font-serif text-2xl font-medium">
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
              <.btn
                variant="ghost"
                size="sm"
                phx-click={JS.dispatch("camerex:copy", to: "#doctor-fix-#{i}")}
              >
                copiar
              </.btn>
            </div>
          </div>

          <.folder_tree tree={@tree} current={@folder} root_count={@root_count} />

          <div class="space-y-1 text-sm">
            <.btn
              variant="secondary"
              size="sm"
              class="w-full justify-start"
              phx-click="open_modal"
              phx-value-modal="new_folder"
            >
              + nova pasta
            </.btn>
            <.btn
              :if={@folder != "" and folder_deletable?(@tree, @items, @folder)}
              variant="ghost"
              size="sm"
              class="w-full justify-start"
              id="delete-folder"
              phx-click="delete_folder"
              phx-value-folder={@folder}
              data-confirm={"Remover a pasta vazia /#{@folder}?"}
            >
              remover esta pasta
            </.btn>
          </div>

          <form id="concurrency-form" phx-change="set_concurrency" class="text-sm">
            <label
              class="text-xs font-semibold text-cx-text-dim"
              title="quantas fotos/vídeos são convertidos ao mesmo tempo. Mais = termina antes, porém usa mais CPU e memória."
            >
              conversões simultâneas
            </label>
            <select
              name="concurrency"
              aria-label="conversões simultâneas (quantas rodam ao mesmo tempo)"
              class="mt-1 w-full rounded border border-cx-border bg-cx-bg px-2 py-1.5"
            >
              <option
                :for={n <- concurrency_options(@concurrency)}
                value={n}
                selected={n == @concurrency}
              >
                {n}
              </option>
            </select>
          </form>
        </aside>

        <main class="min-w-0 flex-1 space-y-4 lg:overflow-y-auto lg:pb-10">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div class="flex items-center gap-3">
              <.breadcrumb folder={@folder} />
              <.jobs_indicator summary={@jobs_summary} />
            </div>
            <div class="flex items-center gap-2 text-sm">
              <.btn variant="primary" id="new-conversion" phx-click="open_convert">
                + nova conversão
              </.btn>
              <.btn
                variant="secondary"
                id="import-button"
                phx-click="open_modal"
                phx-value-modal="import"
              >
                importar pasta
              </.btn>
              <.btn :if={@visible_items != []} variant="secondary" phx-click="select_all">
                selecionar tudo
              </.btn>
              <.btn
                :if={Enum.any?(@items, &(&1["status"] == "done"))}
                variant="secondary"
                id="export-folder"
                href={~p"/export/folder?folder=#{@folder}"}
                download
              >
                baixar tudo (.zip)
              </.btn>
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
                  render_params={@render_params}
                  eyedrop_armed={@eyedrop_armed}
                  calib={@calib}
                  calib_url={@calib_url}
                  calib_error={@calib_error}
                  folder_count={length(@items)}
                  selected_count={MapSet.size(@selected)}
                  reconvert_item={@reconvert_item}
                  user_presets={@user_presets}
                  preset_name={@preset_name}
                  collapsed_tags={@collapsed_layer_tags}
                />
            <% end %>
          </section>

          <%= if hero = featured(assigns) do %>
            <.hero_card item={hero} />
          <% end %>

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
              <.btn variant="primary" phx-click="open_convert">+ nova conversão</.btn>
              <.btn variant="secondary" phx-click="open_modal" phx-value-modal="import">
                importar pasta
              </.btn>
            </div>
          </div>

          <div :if={@items != [] and @visible_items == []} id="filter-empty" class="neon-empty">
            <p class="neon-empty-title">nada bate com os filtros</p>
            <.btn variant="secondary" phx-click="clear_filters">limpar filtros</.btn>
          </div>
        </main>
      </div>

      <%!-- modais: um por vez (@modal). Overlay/card/dialog/fechar vêm do <.modal>;
            Esc é tratado no handler global do #library-root (modal tem prioridade). --%>
      <.modal :if={@modal == :import} id="import-modal" title="importar pasta do disco">
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
            class="cx-input"
          />
          <.btn type="submit" variant="primary" size="sm">escanear</.btn>
        </form>

        <div :if={@import_scan} id="import-scan-result" class="text-sm">
          <%= case @import_scan do %>
            <% {:ok, %{media: media, total_bytes: bytes}} -> %>
              <p>
                <strong>{length(media)}</strong>
                mídia(s) encontrada(s) · {Float.round(bytes / 1_048_576, 1)} MB
              </p>
              <.btn :if={media != []} variant="primary" id="import-run" phx-click="import_run">
                importar tudo
              </.btn>
            <% {:error, msg} -> %>
              <p class="text-cx-orange">{msg}</p>
          <% end %>
        </div>
      </.modal>

      <.modal :if={@modal == :new_folder} id="new-folder-modal" title="nova pasta">
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
            class="cx-input"
          />
          <.btn type="submit" variant="primary" size="sm">criar</.btn>
        </form>
      </.modal>

      <.modal :if={@modal == :colors_json} id="colors-json-modal" title="cores por parte (JSON)">
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
            class="w-full rounded-control border border-cx-border-strong bg-cx-bg p-2 font-mono text-sm text-cx-text"
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
            <.btn type="submit" variant="primary">aplicar cores</.btn>
            <.btn variant="secondary" size="sm" phx-click="close_modal">cancelar</.btn>
          </div>
        </form>
      </.modal>
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

  # destaque da última conversão: 1º item :done (items vêm recente-primeiro), só na
  # biblioteca "pura" — sem painel aberto nem filtro ativo. nil = não renderiza o herói.
  defp featured(
         %{
           current_item: nil,
           reconvert_item: nil,
           convert_open: false,
           query: "",
           status_filter: ""
         } = assigns
       ) do
    Enum.find(assigns.items, &(&1["status"] == "done"))
  end

  defp featured(_assigns), do: nil

  # opções do select de concorrência: degraus úteis + o valor atual (caso seja um
  # ímpar antigo fora dos degraus), sempre ordenado e sem repetir
  defp concurrency_options(current) do
    [1, 2, 3, 4, 5, 6, 8, 12, 16, current] |> Enum.uniq() |> Enum.sort()
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

  defp panel_params(socket), do: panel_params_for(socket, :photo)

  defp panel_params_for(socket, type) do
    socket.assigns.render_params
    |> RenderParams.to_manifest()
    |> Map.put("model", default_model(type))
  end

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
end
