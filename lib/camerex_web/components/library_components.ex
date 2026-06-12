defmodule CamerexWeb.LibraryComponents do
  @moduledoc """
  Componentes da biblioteca: árvore de pastas, breadcrumb, card de item e
  barra de seleção em massa. Todos emitem eventos para o LiveView pai —
  nenhum estado próprio.
  """

  use Phoenix.Component

  import CamerexWeb.NeonComponents

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
    <nav id="breadcrumb" class="flex flex-wrap items-center gap-1 text-sm text-cx-text-dim">
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
        class="absolute left-2 top-2 z-10 h-4 w-4 accent-[#2BC4B2]"
      />

      <button
        type="button"
        phx-click="open_item"
        phx-value-id={@item["id"]}
        aria-label={"abrir #{@item["original_filename"]}"}
        class="block w-full text-left"
      >
        <div :if={@item["status"] == "done"} class="flex gap-1">
          <img
            src={Workspace.media_url(@item["id"], "thumb.jpg")}
            alt="antes"
            loading="lazy"
            class="h-24 w-1/2 rounded object-cover"
          />
          <img
            src={Workspace.media_url(@item["id"], "thumb_neon.jpg")}
            alt="depois"
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
      </button>

      <div class="mt-1.5 flex items-center gap-1.5 text-xs">
        <span data-role="type-chip" class="rounded-full border border-cx-border px-1.5 py-0.5">
          {type_label(@item["type"])}
        </span>
        <.status_badge status={@item["status"]} />
      </div>

      <div :if={@item["status"] == "processing"} data-role="job-progress" class="mt-1.5">
        <%= if @progress do %>
          <div class="h-1.5 rounded bg-cx-border">
            <div class="h-1.5 rounded bg-cx-teal" style={"width: #{progress_pct(@progress)}%"}></div>
          </div>
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

      <button type="button" phx-click="bulk_process" class="neon-cta !mt-0">
        processar com ajustes atuais
      </button>

      <form :if={@user_presets != []} phx-change="bulk_process_preset" class="contents">
        <select name="preset_id" class="rounded border border-cx-border bg-cx-bg px-2 py-1.5">
          <option value="">processar com preset salvo…</option>
          <option :for={p <- @user_presets} value={p["id"]}>{p["name"]}</option>
        </select>
      </form>

      <form phx-change="bulk_move" class="contents">
        <select name="folder" class="rounded border border-cx-border bg-cx-bg px-2 py-1.5">
          <option value="__none__">mover para…</option>
          <option value="">⌂ biblioteca</option>
          <option :for={f <- @folders} value={f}>{f}</option>
        </select>
      </form>

      <button
        type="button"
        phx-click="bulk_duplicate"
        class="rounded border border-cx-border px-3 py-1.5"
      >
        duplicar
      </button>

      <button
        type="button"
        phx-click="bulk_delete"
        data-confirm="Apagar os itens selecionados? Os arquivos serão removidos."
        class="rounded border border-cx-border px-3 py-1.5 text-cx-text-dim"
      >
        apagar
      </button>

      <button type="button" phx-click="clear_selection" class="text-cx-text-dim underline">
        limpar
      </button>
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

  defp progress_pct(%{done: d, total: t}) when t > 0, do: Float.round(d / t * 100, 1)
  defp progress_pct(_), do: 0.0
end
