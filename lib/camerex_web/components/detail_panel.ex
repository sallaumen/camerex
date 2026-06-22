defmodule CamerexWeb.DetailPanel do
  @moduledoc """
  Painel direito de detalhe de um item: antes/depois (imagens ou players),
  parâmetros usados e ações — todas com rótulo de texto visível.
  """

  use Phoenix.Component

  import CamerexWeb.NeonComponents
  import CamerexWeb.UI

  alias Camerex.Workspace

  attr :item, :map, required: true, doc: "manifest do item"
  attr :progress, :map, default: nil

  def detail_panel(assigns) do
    ~H"""
    <section id="detail-panel" class="space-y-4">
      <header class="flex items-start justify-between gap-2">
        <div class="min-w-0">
          <h2 class="truncate text-lg font-semibold">{@item["original_filename"]}</h2>
          <div class="mt-1 flex items-center gap-2 text-xs">
            <.status_badge status={@item["status"]} />
            <span :if={@item["folder"] != ""} class="text-cx-text-dim">
              em /{@item["folder"]}
            </span>
          </div>
        </div>
        <.close_button id="close-detail" phx-click="close_detail" label="fechar detalhe">
          fechar
        </.close_button>
      </header>

      <%!-- antes | depois lado a lado quando há resultado; só "antes" (cheio)
            enquanto não processou. flex-1 + min-w-0 = metades que truncam. --%>
      <div :if={@item["type"] == "video"} class="flex gap-3">
        <figure class="min-w-0 flex-1">
          <figcaption class="mb-1.5 text-sm font-medium text-cx-text-dim">
            antes
          </figcaption>
          <video
            controls
            preload="metadata"
            data-role="video-original"
            class="mx-auto max-h-[72vh] w-full rounded-lg border border-cx-border bg-cx-well object-contain"
            src={Workspace.media_url(@item["id"], @item["original_file"])}
          ></video>
        </figure>
        <figure :if={@item["status"] == "done"} class="min-w-0 flex-1">
          <figcaption class="mb-1.5 text-sm font-medium text-cx-text-dim">
            depois (neon)
          </figcaption>
          <video
            controls
            preload="metadata"
            data-role="video-neon"
            class="mx-auto max-h-[72vh] w-full rounded-lg border border-cx-border bg-cx-well object-contain"
            src={versioned_media_url(@item, @item["output_file"])}
          ></video>
        </figure>
      </div>

      <div :if={@item["type"] != "video"} class="flex gap-3">
        <figure class="min-w-0 flex-1">
          <img
            id="before"
            src={Workspace.media_url(@item["id"], @item["original_file"])}
            alt="antes"
            class="mx-auto max-h-[72vh] w-full rounded-lg border border-cx-border bg-cx-well object-contain"
          />
          <figcaption class="mt-1.5 text-sm font-medium text-cx-text-dim">
            antes
          </figcaption>
        </figure>
        <figure :if={@item["status"] == "done"} class="min-w-0 flex-1">
          <img
            id="after"
            src={versioned_media_url(@item, @item["output_file"])}
            alt="depois"
            class="mx-auto max-h-[72vh] w-full rounded-lg border border-cx-border bg-cx-well object-contain"
          />
          <figcaption class="mt-1.5 text-sm font-medium text-cx-text-dim">
            depois (neon)
          </figcaption>
        </figure>
      </div>

      <div :if={@item["status"] == "processing"} data-role="job-progress">
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

      <dl :if={@item["params"]} id="params" class="grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
        <dt class="text-cx-text-dim">halo</dt>
        <dd>{@item["params"]["halo"]}</dd>
        <dt class="text-cx-text-dim">rastro</dt>
        <dd>{@item["params"]["trail"]}</dd>
        <dt class="text-cx-text-dim">detalhe</dt>
        <dd>{@item["params"]["detail"]}</dd>
      </dl>

      <p :if={@item["error"]} id="error" class="text-sm text-cx-danger">{@item["error"]}</p>

      <div class="flex flex-wrap items-center gap-2 text-sm">
        <.btn
          :if={@item["status"] == "done"}
          variant="primary"
          id="download"
          href={versioned_media_url(@item, @item["output_file"])}
          download={@item["output_file"]}
        >
          Baixar
        </.btn>

        <.btn variant="secondary" id="reconvert-button" phx-click="reconvert_start">
          {if @item["status"] == "new", do: "Processar", else: "Reprocessar com ajustes"}
        </.btn>

        <.btn
          :if={@item["status"] in ["failed", "interrupted"]}
          variant="primary"
          id="retry"
          phx-click="retry_item"
        >
          Tentar de novo
        </.btn>

        <.btn variant="secondary" id="duplicate" phx-click="duplicate_item">Duplicar</.btn>

        <.btn
          variant="danger"
          id="delete"
          phx-click="delete_item"
          data-confirm="Apagar esta conversão? Os arquivos serão removidos."
        >
          Apagar
        </.btn>
      </div>
    </section>
    """
  end
end
