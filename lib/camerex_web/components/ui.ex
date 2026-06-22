defmodule CamerexWeb.UI do
  @moduledoc """
  Design system "neon refinado" — primitivos reutilizáveis (botão, badge, card,
  barra de progresso, input/select, botão de fechar). Encapsulam raio, padding,
  cor, foco e estados num só lugar (ver docs/design/2026-06-22-redesign-neon-refinado.md).

  Convenções: todo controle tem hover, foco visível (anel sólido teal, global no
  app.css), :active (scale .97) e disabled. Glow é racionado — só o botão primário
  carrega a assinatura.
  """
  use Phoenix.Component

  import CamerexWeb.CoreComponents, only: [icon: 1]

  @doc """
  Botão coeso. Renderiza `<button>` ou `<.link>` (quando recebe navigate/patch/href).

  ## Exemplos

      <.btn variant="primary">processar</.btn>
      <.btn variant="secondary" size="sm" phx-click="cancel">cancelar</.btn>
      <.btn variant="danger" phx-click="delete" data-confirm="tem certeza?">apagar</.btn>
  """
  attr :variant, :string, default: "secondary", values: ~w(primary secondary ghost danger)
  attr :size, :string, default: "md", values: ~w(sm md)
  attr :type, :string, default: "button"
  attr :loading, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :class, :any, default: nil

  attr :rest, :global,
    include:
      ~w(href navigate patch method download name value form phx-click phx-value-modal phx-value-folder data-confirm)

  slot :inner_block, required: true

  def btn(assigns) do
    assigns = assign(assigns, :classes, btn_classes(assigns))

    ~H"""
    <.link :if={link?(@rest)} class={@classes} {@rest}>
      {render_slot(@inner_block)}
    </.link>
    <button
      :if={!link?(@rest)}
      type={@type}
      class={@classes}
      disabled={@disabled or @loading}
      {@rest}
    >
      <.icon :if={@loading} name="hero-arrow-path" class="size-4 animate-spin" />
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp link?(rest), do: rest[:href] || rest[:navigate] || rest[:patch]

  defp btn_classes(assigns) do
    [
      "cx-btn",
      "cx-btn-#{assigns.size}",
      "cx-btn-#{assigns.variant}",
      assigns.class
    ]
  end

  @doc """
  Botão de fechar/ícone coeso (substitui as várias versões divergentes de "fechar").
  """
  attr :label, :string, required: true, doc: "rótulo acessível (aria-label)"
  attr :icon, :string, default: "hero-x-mark"
  attr :rest, :global, include: ~w(phx-click phx-value-modal)
  slot :inner_block

  def close_button(assigns) do
    ~H"""
    <button type="button" class="cx-btn cx-btn-ghost cx-btn-sm" aria-label={@label} {@rest}>
      {render_slot(@inner_block)}
      <.icon name={@icon} class="size-4" />
    </button>
    """
  end

  @doc """
  Badge/chip de estado ou tipo. Unifica status e type-chip num único componente.
  `processing` pulsa (desligado em prefers-reduced-motion pelo bloco global do app.css).
  """
  attr :tone, :string,
    default: "neutral",
    values: ~w(neutral info success warning danger processing)

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={["neon-badge", badge_tone_class(@tone), @class]} {@rest}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_tone_class("neutral"), do: "badge-new"
  defp badge_tone_class("info"), do: "badge-done"
  defp badge_tone_class("success"), do: "badge-done"
  defp badge_tone_class("warning"), do: "badge-interrupted"
  defp badge_tone_class("danger"), do: "badge-failed"
  defp badge_tone_class("processing"), do: "badge-processing"

  @doc """
  Card: superfície com borda hairline. `interactive` sobe a elevação no hover.
  """
  attr :interactive, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div
      class={[
        "rounded-card border border-cx-border bg-cx-surface",
        @interactive && "neon-card",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Barra de progresso acessível. Aceita `value` (0..100) ou `done`/`total`.
  O preenchimento usa scaleX (composite, desliza suave a cada push).
  """
  attr :value, :integer, default: nil
  attr :done, :integer, default: nil
  attr :total, :integer, default: nil
  attr :class, :any, default: nil

  def progress(assigns) do
    assigns = assign(assigns, :pct, progress_pct(assigns))

    ~H"""
    <div
      class={["h-1.5 overflow-hidden rounded-full bg-cx-elevated", @class]}
      role="progressbar"
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={@pct}
    >
      <div
        class="cx-progress-fill h-full rounded-full bg-cx-teal"
        style={"transform: scaleX(#{@pct / 100})"}
      >
      </div>
    </div>
    """
  end

  @doc "Porcentagem 0..100 a partir de `value` ou `done`/`total`. Função pura."
  def progress_pct(%{value: v}) when is_integer(v), do: clamp_pct(v)

  def progress_pct(%{done: d, total: t}) when is_integer(d) and is_integer(t) and t > 0,
    do: clamp_pct(round(d / t * 100))

  def progress_pct(_), do: 0

  defp clamp_pct(p) when p < 0, do: 0
  defp clamp_pct(p) when p > 100, do: 100
  defp clamp_pct(p), do: p

  @doc """
  Input de texto coeso (classe `.cx-input`). Para selects, use `select/1`.
  """
  attr :type, :string, default: "text"
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :label, :string, default: nil
  attr :class, :any, default: nil

  attr :rest, :global,
    include:
      ~w(placeholder min max step required disabled phx-debounce phx-change id autocomplete inputmode)

  def input(assigns) do
    ~H"""
    <label :if={@label} class="block text-label text-cx-text-dim">{@label}</label>
    <input type={@type} name={@name} value={@value} class={["cx-input", @class]} {@rest} />
    """
  end

  @doc """
  Select coeso (classe `.cx-input`). `options` no formato de `Phoenix.HTML.Form.options_for_select/2`.
  """
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :label, :string, default: nil
  attr :options, :list, required: true
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(required disabled phx-change id)

  def select(assigns) do
    ~H"""
    <label :if={@label} class="block text-label text-cx-text-dim">{@label}</label>
    <select name={@name} class={["cx-input", @class]} {@rest}>
      {Phoenix.HTML.Form.options_for_select(@options, @value)}
    </select>
    """
  end
end
