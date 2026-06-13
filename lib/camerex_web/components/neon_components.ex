defmodule CamerexWeb.NeonComponents do
  @moduledoc "Componentes visuais do tema neon: badges de status e swatches de preset."

  use Phoenix.Component

  alias Camerex.Neon.Palette
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

  attr :preset, :map, required: true
  attr :selected, :boolean, default: false
  attr :rest, :global

  def preset_swatch(assigns) do
    ~H"""
    <button
      type="button"
      class={["neon-swatch", @selected && "neon-swatch-selected"]}
      style={swatch_style(@preset)}
      data-swatch={@preset.id}
      data-selected={to_string(@selected)}
      title={@preset.name}
      aria-label={"preset de cor #{@preset.name}"}
      {@rest}
    ></button>
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

  # o glow é a própria cor do preset via custom property --glow (box-shadow no CSS)
  defp swatch_style(%{colors: [color]}) do
    "background:#{Palette.hex(color)};--glow:#{Palette.hex(color)}"
  end

  defp swatch_style(%{colors: [left, right]}) do
    "background:linear-gradient(90deg,#{Palette.hex(left)},#{Palette.hex(right)});--glow:#{Palette.hex(left)}"
  end

  defp swatch_style(%{colors: [a, b, c]}) do
    "background:linear-gradient(160deg,#{Palette.hex(a)},#{Palette.hex(b)},#{Palette.hex(c)});" <>
      "--glow:#{Palette.hex(b)}"
  end
end
