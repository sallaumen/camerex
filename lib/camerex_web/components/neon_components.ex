defmodule CamerexWeb.NeonComponents do
  @moduledoc "Componentes visuais do tema neon: badges de status."

  use Phoenix.Component

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
end
