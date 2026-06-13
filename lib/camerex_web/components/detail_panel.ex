defmodule CamerexWeb.DetailPanel do
  @moduledoc """
  Painel direito de detalhe de um item: antes/depois (imagens ou players),
  parâmetros usados e ações — todas com rótulo de texto visível.
  """

  use Phoenix.Component

  import CamerexWeb.NeonComponents

  alias Camerex.Workspace

  attr :item, :map, required: true, doc: "manifest do item"
  attr :progress, :map, default: nil

  def detail_panel(assigns) do
    ~H"""
    <section id="detail-panel" class="space-y-4">
      <header class="flex items-start justify-between gap-2">
        <div>
          <h2 class="truncate text-lg font-semibold">{@item["original_filename"]}</h2>
          <div class="mt-1 flex items-center gap-2 text-xs">
            <.status_badge status={@item["status"]} />
            <span :if={@item["folder"] != ""} class="text-cx-text-dim">
              em /{@item["folder"]}
            </span>
          </div>
        </div>
        <button
          type="button"
          id="close-detail"
          phx-click="close_detail"
          aria-label="fechar detalhe"
          class="rounded border border-cx-border px-2 py-1 text-sm text-cx-text-dim"
        >
          fechar ✕
        </button>
      </header>

      <div :if={@item["type"] == "video"} class="space-y-3">
        <figure>
          <figcaption class="mb-1 text-xs text-cx-text-dim">antes</figcaption>
          <video
            controls
            preload="metadata"
            data-role="video-original"
            class="w-full rounded-lg border border-cx-border"
            src={Workspace.media_url(@item["id"], @item["original_file"])}
          ></video>
        </figure>
        <figure :if={@item["status"] == "done"}>
          <figcaption class="mb-1 text-xs text-cx-text-dim">depois (neon)</figcaption>
          <video
            controls
            preload="metadata"
            data-role="video-neon"
            class="w-full rounded-lg border border-cx-border"
            src={versioned_media_url(@item, @item["output_file"])}
          ></video>
        </figure>
      </div>

      <div :if={@item["type"] != "video"} class="space-y-3">
        <figure>
          <img
            id="before"
            src={Workspace.media_url(@item["id"], @item["original_file"])}
            alt="antes"
            class="w-full rounded-lg border border-cx-border"
          />
          <figcaption class="mt-1 text-xs text-cx-text-dim">antes</figcaption>
        </figure>
        <figure :if={@item["status"] == "done"}>
          <img
            id="after"
            src={versioned_media_url(@item, @item["output_file"])}
            alt="depois"
            class="w-full rounded-lg border border-cx-border"
          />
          <figcaption class="mt-1 text-xs text-cx-text-dim">depois (neon)</figcaption>
        </figure>
      </div>

      <div :if={@item["status"] == "processing"} data-role="job-progress">
        <%= if @progress do %>
          <div class="h-1.5 rounded bg-cx-border">
            <div class="h-1.5 rounded bg-cx-teal" style={"width: #{pct(@progress)}%"}></div>
          </div>
          <span class="text-xs text-cx-text-dim">
            {@progress.done}/{@progress.total}{if @progress.eta_s,
              do: " · ~#{round(@progress.eta_s)}s"}
          </span>
        <% else %>
          <span class="text-xs text-cx-text-dim">processando…</span>
        <% end %>
      </div>

      <dl :if={@item["params"]} id="params" class="grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
        <dt class="text-cx-text-dim">preset</dt>
        <dd>{@item["preset"]}</dd>
        <dt class="text-cx-text-dim">halo</dt>
        <dd>{@item["params"]["halo"]}</dd>
        <dt class="text-cx-text-dim">rastro</dt>
        <dd>{@item["params"]["trail"]}</dd>
        <dt class="text-cx-text-dim">detalhe</dt>
        <dd>{@item["params"]["detail"]}</dd>
      </dl>

      <p :if={@item["error"]} id="error" class="text-sm text-red-300">{@item["error"]}</p>

      <div class="flex flex-wrap items-center gap-2 text-sm">
        <a
          :if={@item["status"] == "done"}
          id="download"
          href={versioned_media_url(@item, @item["output_file"])}
          download={@item["output_file"]}
          class="rounded bg-cx-teal px-3 py-1.5 font-medium text-cx-bg"
        >
          Baixar
        </a>

        <button
          type="button"
          id="reconvert-button"
          phx-click="reconvert_start"
          class="rounded border border-cx-teal px-3 py-1.5 text-cx-teal"
        >
          {if @item["status"] == "new", do: "Processar", else: "Reprocessar com ajustes"}
        </button>

        <button
          :if={@item["status"] in ["failed", "interrupted"]}
          type="button"
          id="retry"
          phx-click="retry_item"
          class="rounded bg-cx-orange px-3 py-1.5 font-medium text-cx-bg"
        >
          Tentar de novo
        </button>

        <button
          type="button"
          id="duplicate"
          phx-click="duplicate_item"
          class="rounded border border-cx-border px-3 py-1.5"
        >
          Duplicar
        </button>

        <button
          type="button"
          id="delete"
          phx-click="delete_item"
          data-confirm="Apagar esta conversão? Os arquivos serão removidos."
          class="rounded border border-cx-border px-3 py-1.5 text-cx-text-dim"
        >
          Apagar
        </button>
      </div>
    </section>
    """
  end

  defp pct(%{done: d, total: t}) when t > 0, do: Float.round(d / t * 100, 1)
  defp pct(_), do: 0.0
end
