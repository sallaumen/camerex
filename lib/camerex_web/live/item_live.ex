defmodule CamerexWeb.ItemLive do
  use CamerexWeb, :live_view

  alias Camerex.Jobs
  alias Camerex.Workspace

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Jobs.subscribe()

    case Workspace.manifest(id) do
      {:ok, manifest} ->
        {:ok, assign(socket, id: id, manifest: manifest)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Conversão não encontrada.")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:jobs_changed}, socket) do
    case Workspace.manifest(socket.assigns.id) do
      {:ok, manifest} -> {:noreply, assign(socket, :manifest, manifest)}
      {:error, :not_found} -> {:noreply, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("delete", _params, socket) do
    :ok = Workspace.delete_item(socket.assigns.id)

    {:noreply,
     socket
     |> put_flash(:info, "Conversão apagada.")
     |> push_navigate(to: ~p"/")}
  end

  def handle_event("retry", _params, socket) do
    id = socket.assigns.id

    {:ok, manifest} =
      Workspace.update_manifest(id, fn m ->
        m |> Map.put("status", "queued") |> Map.put("error", nil)
      end)

    :ok = Jobs.enqueue(id)
    {:noreply, assign(socket, :manifest, manifest)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-5xl p-6">
        <.link navigate={~p"/"} class="text-sm text-cx-text-dim">&larr; galeria</.link>
        <h1 class="mt-2 truncate text-xl font-semibold">{@manifest["original_filename"]}</h1>

        <div :if={@manifest["type"] == "video"} class="mt-6 grid grid-cols-1 gap-4 sm:grid-cols-2">
          <figure>
            <figcaption class="mb-1 text-xs text-cx-text-dim">antes</figcaption>
            <video
              controls
              preload="metadata"
              data-role="video-original"
              class="w-full rounded-lg border border-cx-border"
              src={Workspace.media_url(@id, @manifest["original_file"])}
            ></video>
          </figure>

          <figure :if={@manifest["status"] == "done"}>
            <figcaption class="mb-1 text-xs text-cx-text-dim">depois (neon)</figcaption>
            <video
              controls
              preload="metadata"
              data-role="video-neon"
              class="w-full rounded-lg border border-cx-border"
              src={Workspace.media_url(@id, @manifest["output_file"])}
            ></video>
          </figure>

          <p :if={@manifest["status"] != "done"} id="status-note" class="self-center text-cx-text-dim">
            {status_note(@manifest["status"])}
          </p>
        </div>

        <div :if={@manifest["type"] != "video"} class="mt-6 grid grid-cols-1 gap-4 sm:grid-cols-2">
          <figure>
            <img
              id="before"
              src={Workspace.media_url(@id, @manifest["original_file"])}
              alt="antes"
              class="w-full rounded-lg border border-cx-border"
            />
            <figcaption class="mt-1 text-xs text-cx-text-dim">antes</figcaption>
          </figure>

          <figure :if={@manifest["status"] == "done"}>
            <img
              id="after"
              src={Workspace.media_url(@id, @manifest["output_file"])}
              alt="depois"
              class="w-full rounded-lg border border-cx-border"
            />
            <figcaption class="mt-1 text-xs text-cx-text-dim">depois</figcaption>
          </figure>

          <p :if={@manifest["status"] != "done"} id="status-note" class="self-center text-cx-text-dim">
            {status_note(@manifest["status"])}
          </p>
        </div>

        <dl id="params" class="mt-6 grid grid-cols-2 gap-x-6 gap-y-1 text-sm sm:grid-cols-4">
          <dt class="text-cx-text-dim">preset</dt>
          <dd>{@manifest["preset"]}</dd>
          <dt class="text-cx-text-dim">halo</dt>
          <dd>{@manifest["params"]["halo"]}</dd>
          <dt class="text-cx-text-dim">rastro</dt>
          <dd>{@manifest["params"]["trail"]}</dd>
          <dt class="text-cx-text-dim">detalhe</dt>
          <dd>{@manifest["params"]["detail"]}</dd>
        </dl>

        <div class="mt-6 flex items-center gap-3">
          <a
            :if={@manifest["status"] == "done"}
            id="download"
            href={Workspace.media_url(@id, @manifest["output_file"])}
            download={@manifest["output_file"]}
            class="rounded bg-cx-teal px-4 py-2 text-sm font-medium text-cx-bg"
          >
            Baixar
          </a>
          <button
            :if={@manifest["status"] in ["failed", "interrupted"]}
            id="retry"
            phx-click="retry"
            class="rounded bg-cx-orange px-4 py-2 text-sm font-medium text-cx-bg"
          >
            Tentar de novo
          </button>
          <button
            id="delete"
            phx-click="delete"
            data-confirm="Apagar esta conversão? Os arquivos serão removidos."
            class="rounded border border-cx-border px-4 py-2 text-sm text-cx-text-dim"
          >
            Apagar
          </button>
        </div>

        <p :if={@manifest["error"]} id="error" class="mt-4 text-sm text-red-300">
          {@manifest["error"]}
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp status_note("queued"), do: "na fila — aguardando processamento"
  defp status_note("processing"), do: "processando…"
  defp status_note("failed"), do: "a conversão falhou"
  defp status_note("interrupted"), do: "interrompida por um restart"
  defp status_note(_), do: ""
end
