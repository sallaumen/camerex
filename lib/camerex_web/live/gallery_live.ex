defmodule CamerexWeb.GalleryLive do
  use CamerexWeb, :live_view

  alias Camerex.Jobs
  alias Camerex.Workspace

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Jobs.subscribe()
    {:ok, load_items(socket)}
  end

  @impl true
  def handle_info({:jobs_changed}, socket), do: {:noreply, load_items(socket)}

  defp load_items(socket), do: assign(socket, :items, Workspace.list_items())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-6xl p-6">
        <h1 class="text-2xl font-semibold">camerex</h1>

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
            <p :if={item["error"]} class="mt-1 truncate text-xs text-cx-text-dim" title={item["error"]}>
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
