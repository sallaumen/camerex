defmodule CamerexWeb.LibraryComponents do
  @moduledoc """
  Componentes da biblioteca: árvore de pastas, breadcrumb, card de item e
  barra de seleção em massa. Todos emitem eventos para o LiveView pai —
  nenhum estado próprio.
  """

  use Phoenix.Component

  import CamerexWeb.CoreComponents, only: [icon: 1]
  import CamerexWeb.NeonComponents
  import CamerexWeb.UI

  alias Camerex.Workspace

  attr :tree, :list, required: true, doc: "saída de Library.tree/0"
  attr :current, :string, required: true, doc: "pasta selecionada (\"\" = raiz)"
  attr :root_count, :integer, required: true

  def folder_tree(assigns) do
    ~H"""
    <nav id="folder-tree" class="space-y-0.5 text-sm">
      <button
        type="button"
        phx-click="select_folder"
        phx-value-folder=""
        data-folder=""
        class={["w-full rounded px-2 py-1 text-left", tree_row_class(@current == "")]}
      >
        <span class="text-cx-text-dim">⌂</span>
        biblioteca <span class="float-right text-xs text-cx-text-dim">{@root_count}</span>
      </button>

      <button
        :for={node <- @tree}
        type="button"
        phx-click="select_folder"
        phx-value-folder={node.path}
        data-folder={node.path}
        class={["w-full rounded px-2 py-1 text-left", tree_row_class(@current == node.path)]}
        style={"padding-left: #{0.5 + depth(node.path) * 0.85}rem"}
      >
        <span class="text-cx-text-dim">▸</span> {basename(node.path)}
        <span class="float-right text-xs text-cx-text-dim">{node.count}</span>
      </button>
    </nav>
    """
  end

  attr :folder, :string, required: true

  def breadcrumb(assigns) do
    assigns = assign(assigns, :crumbs, crumbs(assigns.folder))

    ~H"""
    <nav
      id="breadcrumb"
      class="flex flex-wrap items-center gap-1 font-serif text-base text-cx-text-dim"
    >
      <button type="button" phx-click="select_folder" phx-value-folder="" class="hover:text-cx-text">
        biblioteca
      </button>
      <span :for={{name, path} <- @crumbs} class="flex items-center gap-1">
        <span>/</span>
        <button
          type="button"
          phx-click="select_folder"
          phx-value-folder={path}
          class="hover:text-cx-text"
        >
          {name}
        </button>
      </span>
    </nav>
    """
  end

  attr :item, :map, required: true, doc: "último item :done — destaque da última conversão"

  @doc """
  Card-herói: vitrine da última conversão pronta, no topo da biblioteca. Resultado neon
  em destaque com inset do \"antes\" + pílula; à direita badge, título serif, barras de
  parâmetro (read-only) e ações Baixar/Abrir. Reusa status_badge/param_bar/btn do kit.
  """
  def hero_card(assigns) do
    ~H"""
    <section id="hero" class="neon-card overflow-hidden p-0">
      <div class="grid gap-0 lg:grid-cols-[1.55fr_1fr]">
        <div class="relative bg-cx-well">
          <img
            src={Workspace.versioned_media_url(@item, "thumb_neon.jpg")}
            alt={"última conversão — #{@item["original_filename"]} (neon)"}
            class="aspect-[16/10] w-full object-cover"
          />
          <span class="neon-badge badge-done absolute right-3 top-3">depois · neon</span>
          <img
            src={Workspace.versioned_media_url(@item, "thumb.jpg")}
            alt=""
            class="absolute bottom-3 left-3 h-20 w-28 rounded border border-cx-text/20 object-cover shadow-lg"
          />
        </div>

        <div class="flex flex-col gap-3 p-5">
          <div class="flex items-center gap-2 text-xs">
            <.status_badge status={@item["status"]} />
            <span class="font-mono text-cx-text-faint">última conversão</span>
          </div>

          <h2 class="truncate font-serif text-2xl font-medium" title={@item["original_filename"]}>
            {@item["original_filename"]}
          </h2>

          <div :if={@item["params"]} class="space-y-2">
            <.param_bar label="Halo" value={@item["params"]["halo"]} max={1.0} />
            <.param_bar label="Rastro" value={@item["params"]["trail"]} max={0.95} />
            <.param_bar label="Detalhe" value={@item["params"]["detail"]} max={1.0} />
          </div>

          <div class="mt-auto flex flex-wrap items-center gap-2">
            <.btn
              variant="primary"
              href={Workspace.versioned_media_url(@item, @item["output_file"])}
              download={@item["output_file"]}
            >
              Baixar
            </.btn>
            <.btn variant="secondary" phx-click="edit_item" phx-value-id={@item["id"]}>
              Editar
            </.btn>
            <.btn variant="ghost" phx-click="open_item" phx-value-id={@item["id"]}>
              Abrir
            </.btn>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :item, :map, required: true, doc: "manifest do item"
  attr :selected, :boolean, default: false
  attr :progress, :map, default: nil, doc: "%{done, total, eta_s} quando processing"
  attr :active, :boolean, default: false, doc: "aberto no painel de detalhe"

  def item_card(assigns) do
    ~H"""
    <article
      id={"item-#{@item["id"]}"}
      class={["neon-card relative p-2", @active && "ring-1 ring-cx-teal"]}
      data-selected={to_string(@selected)}
    >
      <input
        type="checkbox"
        checked={@selected}
        phx-click="toggle_select"
        phx-value-id={@item["id"]}
        aria-label={"selecionar #{@item["original_filename"]}"}
        class="absolute left-2 top-2 z-10 h-6 w-6 accent-cx-teal"
      />

      <button
        :if={@item["status"] not in ~w(queued processing)}
        type="button"
        phx-click="edit_item"
        phx-value-id={@item["id"]}
        aria-label={"editar #{@item["original_filename"]}"}
        title="editar"
        class="absolute right-2 top-2 z-10 grid size-7 place-items-center rounded bg-cx-bg/80 text-cx-text-dim transition hover:bg-cx-elevated hover:text-cx-teal"
      >
        <.icon name="hero-pencil-square" class="size-4" />
      </button>

      <button
        type="button"
        phx-click="open_item"
        phx-value-id={@item["id"]}
        aria-label={"abrir #{@item["original_filename"]}"}
        class="relative block w-full text-left"
      >
        <div :if={@item["status"] == "done"} class="flex gap-1">
          <img
            src={Workspace.versioned_media_url(@item, "thumb.jpg")}
            alt=""
            loading="lazy"
            class="h-24 w-1/2 rounded object-cover"
          />
          <img
            src={Workspace.versioned_media_url(@item, "thumb_neon.jpg")}
            alt=""
            loading="lazy"
            class="h-24 w-1/2 rounded object-cover"
          />
        </div>
        <img
          :if={@item["status"] != "done" and @item["type"] != "video"}
          src={Workspace.media_url(@item["id"], @item["original_file"])}
          alt={"original de #{@item["original_filename"]}"}
          loading="lazy"
          class="h-24 w-full rounded object-cover"
        />
        <div
          :if={@item["status"] != "done" and @item["type"] == "video"}
          data-role="placeholder"
          class="flex h-24 items-center justify-center rounded bg-cx-bg px-2 text-center text-xs text-cx-text-dim"
        >
          {@item["original_filename"]}
        </div>

        <div
          :if={@item["status"] == "processing"}
          data-role="ring"
          class="absolute inset-0 grid place-items-center rounded bg-cx-bg/65"
        >
          <div :if={@progress} class="cx-ring" style={"--cx-ring-pct: #{ring_pct(@progress)}"}>
            <span class="font-mono text-[0.65rem] tabular-nums text-cx-text">
              {ring_pct(@progress)}%
            </span>
          </div>
          <div :if={!@progress} class="cx-spinner" aria-hidden="true"></div>
        </div>
      </button>

      <div class="mt-1.5 flex items-center gap-1.5 text-xs">
        <.badge tone="neutral" data-role="type-chip">{type_label(@item["type"])}</.badge>
        <.status_badge status={@item["status"]} />
      </div>

      <p class="mt-1 truncate text-sm text-cx-text" title={@item["original_filename"]}>
        {@item["original_filename"]}
      </p>

      <div :if={@item["status"] == "processing"} data-role="job-progress" class="mt-1.5">
        <%= if @progress do %>
          <.progress done={@progress.done} total={@progress.total} class="mb-0.5" />
          <span class="text-xs text-cx-text-dim">
            {@progress.done}/{@progress.total}{if @progress.eta_s,
              do: " · ~#{round(@progress.eta_s)}s"}
          </span>
        <% else %>
          <span class="text-xs text-cx-text-dim">processando…</span>
        <% end %>
      </div>
    </article>
    """
  end

  attr :query, :string, required: true
  attr :status, :string, required: true, doc: "\"\" = todos"
  attr :count, :integer, required: true, doc: "itens visíveis após o filtro"
  attr :total, :integer, required: true, doc: "itens na pasta"

  def filter_bar(assigns) do
    ~H"""
    <form id="filter-form" phx-change="filter" class="flex flex-wrap items-center gap-2 text-sm">
      <input
        type="search"
        name="q"
        value={@query}
        placeholder="buscar por nome…"
        phx-debounce="250"
        autocomplete="off"
        aria-label="buscar itens por nome"
        class="w-56 rounded border border-cx-border bg-cx-bg px-2 py-1.5"
      />
      <select
        name="status"
        aria-label="filtrar por status"
        class="rounded border border-cx-border bg-cx-bg px-2 py-1.5"
      >
        <option value="" selected={@status == ""}>todos os status</option>
        <option :for={{value, label} <- status_options()} value={value} selected={@status == value}>
          {label}
        </option>
      </select>
      <span
        :if={@query != "" or @status != ""}
        data-role="filter-count"
        aria-live="polite"
        class="text-xs text-cx-text-dim"
      >
        {@count} de {@total}
      </span>
    </form>
    """
  end

  defp status_options do
    [
      {"new", "novo"},
      {"queued", "na fila"},
      {"processing", "processando"},
      {"done", "pronto"},
      {"failed", "falhou"},
      {"interrupted", "interrompido"}
    ]
  end

  attr :count, :integer, required: true
  attr :user_presets, :list, required: true
  attr :folders, :list, required: true, doc: "paths para o mover ▾"

  def selection_bar(assigns) do
    ~H"""
    <div
      id="selection-bar"
      class="flex flex-wrap items-center gap-2 rounded-lg border border-cx-teal bg-cx-surface p-2 text-sm"
    >
      <strong>{@count} selecionado(s)</strong>

      <.btn variant="primary" phx-click="bulk_process">processar com ajustes atuais</.btn>

      <form
        :if={@user_presets != []}
        id="bulk-preset-form"
        phx-change="bulk_process_preset"
        class="contents"
      >
        <select name="preset_id" class="rounded border border-cx-border bg-cx-bg px-2 py-1.5">
          <option value="">processar com preset salvo…</option>
          <option :for={p <- @user_presets} value={p["id"]}>{p["name"]}</option>
        </select>
      </form>

      <form id="bulk-move-form" phx-change="bulk_move" class="contents">
        <select name="folder" class="rounded border border-cx-border bg-cx-bg px-2 py-1.5">
          <option value="__none__">mover para…</option>
          <option value="">⌂ biblioteca</option>
          <option :for={f <- @folders} value={f}>{f}</option>
        </select>
      </form>

      <.btn variant="secondary" size="sm" phx-click="bulk_duplicate">duplicar</.btn>

      <.btn
        variant="danger"
        size="sm"
        phx-click="bulk_delete"
        data-confirm="Apagar os itens selecionados? Os arquivos serão removidos."
      >
        apagar
      </.btn>

      <.btn variant="ghost" size="sm" phx-click="clear_selection">limpar</.btn>
    </div>
    """
  end

  defp tree_row_class(true), do: "bg-cx-surface text-cx-text ring-1 ring-cx-border"
  defp tree_row_class(false), do: "text-cx-text-dim hover:text-cx-text"

  defp depth(path), do: path |> String.split("/") |> length() |> Kernel.-(1)

  defp basename(path), do: path |> String.split("/") |> List.last()

  defp crumbs(""), do: []

  defp crumbs(folder) do
    segments = String.split(folder, "/")

    segments
    |> Enum.with_index(1)
    |> Enum.map(fn {name, i} -> {name, segments |> Enum.take(i) |> Enum.join("/")} end)
  end

  defp type_label("video"), do: "vídeo"
  defp type_label(_), do: "foto"

  defp ring_pct(%{done: d, total: t}) when is_integer(d) and is_integer(t) and t > 0,
    do: round(d / t * 100)

  defp ring_pct(_), do: 0

  @doc """
  Status bar persistente na base (estilo VS Code/Resolve): cpu/ram/beam como
  micro-medidores inline + threads/frame do vídeo. `perf` vem de
  `Camerex.SystemStats.snapshot/0`. Emite `set_frame_concurrency` pro LiveView.
  """
  attr :perf, :map, required: true, doc: "snapshot de Camerex.SystemStats"
  attr :frame_concurrency, :integer, required: true

  def perf_dashboard(assigns) do
    ~H"""
    <div
      id="perf-dashboard"
      class="fixed inset-x-0 bottom-0 z-30 flex items-center gap-x-4 gap-y-1 overflow-x-auto border-t border-cx-border bg-cx-surface px-4 py-1.5 text-xs text-cx-text-dim"
    >
      <span class="font-semibold" title="uso de recursos da máquina, em tempo real">desempenho</span>
      <.perf_meter label="cpu" pct={@perf.cpu_pct} />
      <.perf_meter label="ram" pct={ram_pct(@perf.mem)} note={ram_note(@perf.mem)} />
      <span
        class="hidden whitespace-nowrap sm:inline"
        title="memória usada agora pela máquina virtual do Elixir (BEAM)"
      >
        beam <span class="text-cx-text tabular-nums">{@perf.beam_mb} MB</span>
      </span>
      <span class="hidden whitespace-nowrap md:inline" title="núcleos de CPU desta máquina">
        {@perf.schedulers} cores
      </span>

      <form
        id="frame-concurrency-form"
        phx-change="set_frame_concurrency"
        class="ml-auto flex items-center gap-2"
      >
        <label
          for="frame-concurrency"
          class="whitespace-nowrap"
          title="threads que cada vídeo usa para processar um frame (paralelismo interno de uma conversão, diferente de quantas conversões rodam juntas)"
        >
          threads/frame
        </label>
        <input
          type="number"
          id="frame-concurrency"
          name="frame_concurrency"
          value={@frame_concurrency}
          min="1"
          max="64"
          step="1"
          phx-debounce="300"
          class="w-14 rounded-control border border-cx-border-strong bg-cx-bg px-2 py-0.5 text-right text-cx-text"
        />
        <span class="hidden text-cx-text-faint lg:inline">vale no próximo vídeo</span>
      </form>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :pct, :integer, default: nil
  attr :note, :string, default: nil

  defp perf_meter(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5 whitespace-nowrap">
      <span>{@label}</span>
      <div class="h-1.5 w-14 overflow-hidden rounded-full bg-cx-elevated">
        <div
          class={["h-full rounded-full transition-all duration-500", bar_color(@pct)]}
          style={"width: #{@pct || 0}%"}
        >
        </div>
      </div>
      <span class="text-cx-text tabular-nums">
        {if @pct, do: "#{@pct}%", else: "—"}{if @note, do: " · #{@note}", else: ""}
      </span>
    </div>
    """
  end

  # cor da barra por carga: teal tranquilo · laranja atenção · vermelho no talo
  defp bar_color(nil), do: "bg-cx-border-strong"
  defp bar_color(pct) when pct >= 90, do: "bg-cx-danger"
  defp bar_color(pct) when pct >= 70, do: "bg-cx-orange"
  defp bar_color(_), do: "bg-cx-teal"

  defp ram_pct(nil), do: nil
  defp ram_pct(%{pct: pct}), do: pct

  defp ram_note(nil), do: nil
  defp ram_note(%{used_mb: used, total_mb: total}), do: "#{gb(used)}/#{gb(total)} GB"

  defp gb(mb), do: Float.round(mb / 1024, 1)

  @doc """
  Indicador GLOBAL de processamento (header): aparece quando há jobs rodando ou
  na fila, com o agregado de frames + ETA — visível em qualquer pasta/filtro,
  pra um render longo não parecer travado. `summary` vem de `Jobs.state/0`.
  """
  attr :summary, :map, required: true

  def jobs_indicator(assigns) do
    ~H"""
    <div
      :if={@summary.processing > 0 or @summary.queued > 0}
      id="jobs-indicator"
      class="flex items-center gap-2 rounded-full border border-cx-teal bg-cx-surface py-1 pl-3 pr-1 text-sm"
    >
      <span class={[
        "inline-block h-2 w-2 rounded-full bg-cx-teal",
        not @summary.paused && "animate-pulse"
      ]}></span>
      <span class="text-cx-text">
        {@summary.processing} processando<span
          :if={@summary.queued > 0}
          class="text-cx-text-dim"
        > · {@summary.queued} na fila</span>
      </span>
      <span :if={@summary.total > 0} class="text-cx-text-dim">
        {@summary.done}/{@summary.total} frames<span :if={@summary.eta_s}> · ~{eta_label(
          @summary.eta_s
        )}</span>
      </span>
      <span :if={@summary.paused} class="font-medium text-cx-warning">· pausada</span>
      <button
        type="button"
        phx-click="toggle_queue_pause"
        title={
          if @summary.paused,
            do: "retomar: volta a despachar a fila",
            else: "pausar: não inicia novas conversões; as que já rodam terminam"
        }
        aria-label={if @summary.paused, do: "retomar a fila", else: "pausar a fila"}
        class="ml-0.5 rounded-full px-2 py-0.5 text-xs text-cx-text-dim transition hover:bg-cx-elevated hover:text-cx-teal"
      >
        {if @summary.paused, do: "retomar", else: "pausar"}
      </button>
    </div>
    """
  end

  defp eta_label(s) when s >= 60, do: "#{round(s / 60)}min"
  defp eta_label(s), do: "#{round(s)}s"
end
