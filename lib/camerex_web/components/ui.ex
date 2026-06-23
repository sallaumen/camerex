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
  attr :rest, :global, include: ~w(phx-click phx-value-modal phx-value-folder data-confirm title)
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
  Modal: overlay escuro + card centralizado com semântica de dialog (role,
  aria-modal, aria-labelledby), título com botão de fechar e click-away pra
  fechar. Esc é tratado pelo handler global da página. Aplique o `:if` na
  chamada — só um modal por vez.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :on_close, :any, default: "close_modal", doc: "evento de fechar (phx-click/click-away)"
  attr :rest, :global
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={"#{@id}-overlay"}
      class="cx-overlay-in fixed inset-0 z-40 flex items-center justify-center overflow-y-auto bg-black/60 p-4"
      {@rest}
    >
      <div
        id={@id}
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        phx-hook="FocusTrap"
        phx-click-away={@on_close}
        class="cx-modal-in w-full max-w-lg space-y-3 rounded-lg border border-cx-border bg-cx-elevated p-5 shadow-xl"
      >
        <div class="flex items-center justify-between gap-2">
          <h2 id={"#{@id}-title"} class="font-serif text-lg font-medium">{@title}</h2>
          <.close_button label="fechar" phx-click={@on_close} />
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
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
  Barra de parâmetro read-only: rótulo + valor (mono) + mini-trilho preenchido.
  Mostra a magnitude de um ajuste em `0..max` no detalhe e no card-herói (não editável —
  para editar, use o `slider` do painel de conversão). O preenchimento é warm/neutro de
  propósito (teal fica racionado p/ CTA/foco). Função de view.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true, doc: "valor numérico (float/int/string) em 0..max"
  attr :max, :float, default: 1.0
  attr :class, :any, default: nil

  def param_bar(assigns) do
    assigns = assign(assigns, :pct, param_pct(assigns.value, assigns.max))

    ~H"""
    <div class={["space-y-1", @class]}>
      <div class="flex items-baseline justify-between gap-2 text-sm">
        <span class="text-cx-text-dim">{@label}</span>
        <span class="font-mono text-xs tabular-nums text-cx-text">{@value}</span>
      </div>
      <div class="h-0.5 overflow-hidden rounded-full bg-cx-bg">
        <div
          class="h-full origin-left rounded-full bg-cx-border-strong"
          style={"transform: scaleX(#{@pct / 100})"}
        >
        </div>
      </div>
    </div>
    """
  end

  defp param_pct(value, top) when is_number(top) and top > 0 do
    clamp_pct(round(to_num(value) / top * 100))
  end

  defp param_pct(_value, _top), do: 0

  defp to_num(v) when is_number(v), do: v * 1.0

  defp to_num(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_num(_), do: 0.0

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
      ~w(placeholder min max step required disabled phx-debounce phx-change phx-mounted id autocomplete inputmode)

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

  @doc """
  Slider de faixa (`.cx-range`) com preenchimento teal: a faixa preenchida vai do mínimo
  ao valor (`--cx-fill`, % calculado aqui) e o valor aparece à direita em mono.
  """
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :min, :any, required: true
  attr :max, :any, required: true
  attr :step, :any, default: "0.05"
  attr :title, :string, default: nil, doc: "tooltip explicando o que o controle faz"

  def slider(assigns) do
    pct = round((assigns.value - assigns.min) / (assigns.max - assigns.min) * 100)
    assigns = assign(assigns, :pct, pct)

    ~H"""
    <label class="block space-y-1.5" title={@title}>
      <span class="flex items-baseline justify-between gap-2">
        <span class="text-sm text-cx-text">{@label}</span>
        <span class="font-mono text-xs tabular-nums text-cx-teal">{@value}</span>
      </span>
      <input
        type="range"
        name={@name}
        min={@min}
        max={@max}
        step={@step}
        value={@value}
        phx-debounce="150"
        class="cx-range"
        style={"--cx-fill: #{@pct}%"}
      />
    </label>
    """
  end

  @doc """
  Switch on/off (`.cx-switch`) com o par hidden+checkbox que o form precisa.
  `title` vira tooltip (detalhe no hover); `hint` (curto) ainda aparece abaixo.
  """
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :checked, :boolean, required: true
  attr :id, :string, default: nil
  attr :hint, :string, default: nil
  attr :title, :string, default: nil, doc: "tooltip explicando o que a camada faz"

  def toggle(assigns) do
    ~H"""
    <div>
      <label id={@id} title={@title} class="flex cursor-pointer items-center gap-3">
        <input type="hidden" name={@name} value="false" />
        <input type="checkbox" name={@name} value="true" checked={@checked} class="cx-switch" />
        <span class="text-sm text-cx-text">{@label}</span>
      </label>
      <p :if={@hint} class="mt-1 pl-12 text-xs text-cx-text-dim">{@hint}</p>
    </div>
    """
  end

  @doc "Picker de cor arredondado (`.cx-swatch`, sem a moldura nativa do `<input type=color>`)."
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :aria, :string, required: true
  attr :id, :string, default: nil

  def swatch(assigns) do
    ~H"""
    <label id={@id} class="flex items-center gap-2.5 text-sm text-cx-text">
      <input
        type="color"
        name={@name}
        value={@value}
        phx-debounce="200"
        aria-label={@aria}
        class="cx-swatch"
      />
      <span class="truncate">{@label}</span>
    </label>
    """
  end

  @doc "Card que agrupa controles afins (`.cx-section`), com título discreto (sem caixa-alta)."
  attr :title, :string, default: nil
  attr :class, :any, default: "space-y-3"
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <div class={["cx-section", @class]}>
      <p :if={@title} class="cx-section-title">{@title}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
