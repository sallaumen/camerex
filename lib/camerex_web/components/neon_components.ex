defmodule CamerexWeb.NeonComponents do
  @moduledoc "Componentes visuais do tema neon: badges de status e URL versionada de mídia."

  use Phoenix.Component

  alias Camerex.Workspace

  @badges %{
    "new" => {"novo", "badge-new"},
    "queued" => {"na fila", "badge-queued"},
    "processing" => {"processando", "badge-processing"},
    "done" => {"pronto", "badge-done"},
    "failed" => {"falhou", "badge-failed"},
    "interrupted" => {"interrompido", "badge-interrupted"}
  }
  @default_badge {"na fila", "badge-queued"}

  attr :status, :string, required: true

  def status_badge(assigns) do
    {label, class} = Map.get(@badges, assigns.status, @default_badge)
    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span class={["neon-badge", @class]} data-status={@status} data-role="status-chip">
      {@label}
    </span>
    """
  end

  @doc """
  URL da mídia com versão de cache derivada do `completed_at`. Reprocessar
  sobrescreve o mesmo arquivo na mesma URL — sem o `?v=`, o browser reusa
  a saída antiga do cache e os ajustes parecem não ter efeito.
  """
  def versioned_media_url(item, file) do
    base = Workspace.media_url(item["id"], file)

    case item["completed_at"] do
      nil -> base
      stamp -> "#{base}?v=#{:erlang.phash2(stamp)}"
    end
  end
end
