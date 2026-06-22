defmodule CamerexWeb.ConvertPanel do
  @moduledoc """
  Painel direito de conversão: dropzone, cor por parte (pele, cabelo, roupa…),
  sliders, calibragem ao vivo (prévia que reage aos controles, com atalhos de
  aplicação em massa) e presets salvos do usuário. Em modo reprocesso
  (`reconvert_item`) o submit reaplica os ajustes ao item existente em vez de
  criar um novo.

  Os controles vêm de um kit próprio (`slider/1`, `toggle/1`, `swatch/1`,
  `section/1`) estilizado em `app.css` (`.cx-range`, `.cx-switch`, `.cx-swatch`)
  — nada de range/checkbox/color nativos do browser, que destoavam do tema.
  """

  use Phoenix.Component

  import CamerexWeb.UI

  alias Camerex.Parser.Layers
  alias Phoenix.LiveView.JS

  attr :uploads, :map, required: true
  attr :halo, :float, required: true
  attr :bloom, :float, required: true
  attr :layer_colors, :map, default: %{}
  attr :detect_object, :boolean, default: false
  attr :detect_aerial, :boolean, default: false
  attr :aerial_color, :any, default: {220, 30, 40}
  attr :bg_opacity, :float, default: 0.0
  attr :transparent_bg, :boolean, default: false
  attr :fill, :boolean, default: false
  attr :fill_color, :float, default: 0.45
  attr :fill_texture, :float, default: 0.15
  attr :floor, :boolean, default: false
  attr :glow, :float, default: 0.85
  attr :spread, :float, default: 0.5
  attr :trail, :float, required: true
  attr :detail, :float, required: true
  attr :calib, :any, default: nil, doc: ":preparing | sessão da calibragem ao vivo"
  attr :calib_url, :string, default: nil
  attr :calib_error, :string, default: nil
  attr :folder_count, :integer, default: 0, doc: "itens na pasta atual"
  attr :selected_count, :integer, default: 0
  attr :reconvert_item, :map, default: nil, doc: "manifest quando em modo reprocesso"
  attr :user_presets, :list, default: []
  attr :preset_name, :string, default: ""

  def convert_panel(assigns) do
    ~H"""
    <section id="convert-panel" class="space-y-5">
      <header class="flex items-center justify-between gap-2">
        <h2 class="text-lg font-semibold">
          {if @reconvert_item, do: "Reprocessar", else: "Nova conversão"}
        </h2>
        <.close_button
          id="close-convert"
          phx-click="close_convert"
          label="fechar painel de conversão"
        >
          fechar
        </.close_button>
      </header>

      <div
        :if={@reconvert_item}
        id="reconvert-chip"
        class="flex flex-wrap items-center gap-2 rounded-xl border border-cx-teal bg-cx-bg px-3 py-2 text-sm"
      >
        <span>
          {if @reconvert_item["status"] == "new", do: "processando", else: "reprocessando"}
          <strong>{@reconvert_item["original_filename"]}</strong>
        </span>
        <button type="button" class="text-cx-text-dim underline" phx-click="reconvert_cancel">
          cancelar
        </button>
      </div>

      <%!-- 2 colunas no destaque: prévia GRANDE à esquerda, controles à direita --%>
      <div class="grid gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(320px,380px)]">
        <div id="convert-preview" class="self-start lg:sticky lg:top-4">
          <div
            :if={@calib}
            id="calib-preview"
            class="rounded-xl border border-cx-border bg-cx-bg p-2"
          >
            <p :if={@calib == :preparing and @calib_url == nil} class="p-4 text-sm text-cx-text-dim">
              preparando prévia…
            </p>
            <img
              :if={@calib_url}
              src={@calib_url}
              data-role="calib-img"
              alt="prévia ao vivo da calibragem"
              class="mx-auto max-h-[72vh] w-full rounded-lg object-contain"
            />
            <p :if={@calib_error} class="mt-1 text-sm text-cx-orange">
              prévia falhou: {@calib_error}
            </p>
            <p class="mt-1.5 px-1 text-xs text-cx-text-dim">
              prévia ao vivo · o rastro só aparece no vídeo final
            </p>
          </div>
          <div
            :if={!@calib}
            class="flex min-h-[40vh] items-center justify-center rounded-xl border border-dashed border-cx-border p-6 text-center text-sm text-cx-text-dim"
          >
            a prévia ao vivo aparece aqui assim que você escolher uma mídia
          </div>
        </div>

        <div class="space-y-4">
          <form id="convert-form" phx-submit="convert" phx-change="validate" class="space-y-4">
            <div
              :if={@reconvert_item == nil}
              id="dropzone"
              phx-drop-target={@uploads.media.ref}
              class="rounded-xl border border-dashed border-cx-border bg-cx-bg/40 p-5 text-center transition-colors hover:border-cx-teal"
            >
              <.live_file_input upload={@uploads.media} id="media-input" class="sr-only" />
              <label
                for="media-input"
                class="inline-flex cursor-pointer items-center gap-2 rounded-lg border border-cx-border bg-cx-surface px-3.5 py-2 text-sm font-medium text-cx-text transition hover:border-cx-teal hover:text-cx-teal"
              >
                escolher mídia
              </label>
              <p class="mt-2 text-xs text-cx-text-dim">ou arraste uma foto ou vídeo aqui</p>
              <p :for={err <- upload_errors(@uploads.media)} class="mt-1 text-sm text-red-300">
                {upload_error_label(err)}
              </p>
              <div
                :for={entry <- @uploads.media.entries}
                data-role="upload-entry"
                class="mt-2 text-sm text-cx-text-dim"
              >
                {entry.client_name} — {entry.progress}%
                <p :for={err <- upload_errors(@uploads.media, entry)} class="text-red-300">
                  {upload_error_label(err)}
                </p>
              </div>
            </div>

            <.section title="Luz e contorno">
              <.slider name="halo" label="halo" value={@halo} min={0.0} max={1.0} />
              <.slider name="bloom" label="brilho atmosférico" value={@bloom} min={0.0} max={1.0} />
              <.slider
                :if={not photo_reconvert?(@reconvert_item)}
                name="trail"
                label="rastro"
                value={@trail}
                min={0.0}
                max={0.95}
              />
              <.slider name="detail" label="detalhe" value={@detail} min={0.0} max={1.0} step="0.02" />
            </.section>

            <.section title="Cor por parte">
              <div id="layer-pickers" class="space-y-3">
                <div class="grid grid-cols-2 gap-x-4 gap-y-2.5">
                  <.swatch
                    :for={group <- base_groups()}
                    name={"layer_#{group.key}"}
                    value={Layers.hex(Map.get(@layer_colors, group.key, group.default))}
                    label={group.label}
                    aria={"cor da camada #{group.label}"}
                  />
                </div>
                <button
                  type="button"
                  id="edit-colors-json"
                  phx-click="open_modal"
                  phx-value-modal="colors_json"
                  class="text-sm text-cx-teal underline-offset-2 hover:underline focus-visible:ring-2 focus-visible:ring-cx-teal"
                >
                  editar todas as cores como JSON
                </button>
              </div>
            </.section>

            <.section title="Camadas extras" class="space-y-4">
              <div class="space-y-2">
                <.toggle
                  id="object-toggle"
                  name="detect_object"
                  label="objeto/instrumento na mão"
                  checked={@detect_object}
                  hint="usa um 2º modelo (U²-Net) p/ o que a pessoa segura — instrumento, microfone…"
                />
                <div :if={@detect_object} class="pl-12">
                  <.swatch
                    id="object-color"
                    name={"layer_#{object_group().key}"}
                    value={Layers.hex(Map.get(@layer_colors, :object, object_group().default))}
                    label={object_group().label}
                    aria={"cor da camada #{object_group().label}"}
                  />
                </div>
              </div>

              <div class="space-y-2">
                <.toggle
                  id="aerial-toggle"
                  name="detect_aerial"
                  label="acrobacia aérea (tecido)"
                  checked={@detect_aerial}
                  hint="destaca o tecido vertical (silk) que a pessoa escala, como camada própria"
                />
                <div :if={@detect_aerial} class="space-y-2 pl-12">
                  <label
                    id="aerial-photo-color"
                    class="flex items-center gap-2.5 text-sm text-cx-text"
                  >
                    <input
                      type="color"
                      name="aerial_color"
                      value={Layers.hex(@aerial_color)}
                      phx-debounce="200"
                      aria-label="cor real do tecido na foto"
                      class="cx-swatch"
                    />
                    <span>
                      cor do tecido na foto
                      <span class="text-xs text-cx-text-dim">(pra achá-lo)</span>
                    </span>
                  </label>
                  <.swatch
                    id="aerial-color"
                    name={"layer_#{apparatus_group().key}"}
                    value={Layers.hex(Map.get(@layer_colors, :apparatus, apparatus_group().default))}
                    label={apparatus_group().label}
                    aria={"cor da camada #{apparatus_group().label}"}
                  />
                </div>
              </div>

              <div class="space-y-2">
                <.toggle id="fill-toggle" name="fill" label="preencher as partes" checked={@fill} />
                <div :if={@fill} class="space-y-3 pl-12">
                  <.slider
                    name="fill_color"
                    label="opacidade da cor"
                    value={@fill_color}
                    min={0.0}
                    max={1.0}
                  />
                  <.slider
                    name="fill_texture"
                    label="textura da foto"
                    value={@fill_texture}
                    min={0.0}
                    max={1.0}
                  />
                </div>
              </div>
            </.section>

            <.section title="Fundo e cena" class="space-y-4">
              <div id="background-controls" class="space-y-2">
                <.slider
                  name="bg_opacity"
                  label="opacidade do fundo"
                  value={@bg_opacity}
                  min={0.0}
                  max={1.0}
                />
                <p class="text-xs text-cx-text-dim">a foto original aparece atenuada atrás do neon</p>
                <.toggle
                  id="transparent-toggle"
                  name="transparent_bg"
                  label="fundo transparente"
                  checked={@transparent_bg}
                  hint="só foto/PNG"
                />
              </div>

              <div class="space-y-2">
                <.toggle
                  id="floor-toggle"
                  name="floor"
                  label="luz no chão sob os pés"
                  checked={@floor}
                />
                <div :if={@floor} id="floor-controls" class="space-y-3 pl-12">
                  <.slider name="glow" label="brilho" value={@glow} min={0.0} max={1.0} />
                  <.slider name="spread" label="espalhamento" value={@spread} min={0.0} max={1.0} />
                </div>
              </div>
            </.section>

            <div class="flex flex-wrap items-center gap-2 pt-1">
              <.btn type="submit" variant="primary" id="convert-submit">
                {submit_label(@reconvert_item)}
              </.btn>
              <.btn
                :if={@reconvert_item == nil}
                variant="secondary"
                id="import-only"
                phx-click="import_only"
                title="só importa pra biblioteca; processa quando você quiser"
              >
                só importar
              </.btn>
            </div>
          </form>

          <div :if={@calib} id="calib-apply" class="flex flex-wrap gap-2">
            <.btn
              :if={@folder_count > 0}
              variant="secondary"
              size="sm"
              id="apply-folder"
              phx-click="apply_folder"
              data-confirm={"Aplicar estes ajustes em #{@folder_count} item(ns) desta pasta?"}
            >
              Aplicar nesta pasta ({@folder_count})
            </.btn>
            <.btn
              :if={@selected_count > 0}
              variant="secondary"
              size="sm"
              id="apply-selection"
              phx-click="apply_selection"
            >
              Aplicar na seleção ({@selected_count})
            </.btn>
          </div>

          <div id="user-presets" class="cx-section space-y-3">
            <p class="cx-section-title">Meus presets</p>

            <form id="save-preset-form" phx-submit="save_preset" class="flex items-center gap-2">
              <.input name="name" value={@preset_name} placeholder="nome do preset…" />
              <.btn type="submit" variant="secondary" size="sm">salvar</.btn>
            </form>

            <ul :if={@user_presets != []} class="space-y-1 text-sm">
              <li :for={p <- @user_presets} class="flex items-center gap-2" data-user-preset={p["id"]}>
                <button
                  type="button"
                  phx-click="apply_preset"
                  phx-value-id={p["id"]}
                  class="flex-1 truncate rounded-lg px-2.5 py-1.5 text-left transition hover:bg-cx-bg"
                  title={"aplicar #{p["name"]}"}
                >
                  {p["name"]}
                </button>
                <.close_button
                  label={"apagar preset #{p["name"]}"}
                  phx-click={JS.push("delete_preset", value: %{id: p["id"]})}
                  data-confirm={"Apagar o preset #{p["name"]}?"}
                />
              </li>
            </ul>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # ── kit de controles ──────────────────────────────────────────────

  # slider com preenchimento teal: a faixa preenchida vai do mínimo ao valor
  # (--cx-fill, % calculado aqui), e o valor aparece à direita em mono.
  defp slider(assigns) do
    assigns = assign_new(assigns, :step, fn -> "0.05" end)
    pct = round((assigns.value - assigns.min) / (assigns.max - assigns.min) * 100)
    assigns = assign(assigns, :pct, pct)

    ~H"""
    <label class="block space-y-1.5">
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

  # switch on/off (mantém o par hidden+checkbox que o form precisa) + hint opcional
  defp toggle(assigns) do
    assigns = assign_new(assigns, :hint, fn -> nil end)

    ~H"""
    <div>
      <label id={@id} class="flex cursor-pointer items-center gap-3">
        <input type="hidden" name={@name} value="false" />
        <input type="checkbox" name={@name} value="true" checked={@checked} class="cx-switch" />
        <span class="text-sm text-cx-text">{@label}</span>
      </label>
      <p :if={@hint} class="mt-1 pl-12 text-xs text-cx-text-dim">{@hint}</p>
    </div>
    """
  end

  # picker de cor arredondado (sem a moldura cinza do <input type=color> nativo)
  defp swatch(assigns) do
    assigns = assign_new(assigns, :id, fn -> nil end)

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

  # card que agrupa controles afins, com título discreto (sem caixa-alta)
  defp section(assigns) do
    assigns =
      assigns
      |> assign_new(:title, fn -> nil end)
      |> assign_new(:class, fn -> "space-y-3" end)

    ~H"""
    <div class={["cx-section", @class]}>
      <p :if={@title} class="cx-section-title">{@title}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # ── dados das camadas ─────────────────────────────────────────────

  # :object e :apparatus são camadas opt-in (2º modelo): saem do grid de cores
  # fixas e ganham picker próprio só quando ligadas
  defp base_groups, do: Enum.reject(Layers.groups(), &(&1.key in [:object, :apparatus]))
  defp object_group, do: Enum.find(Layers.groups(), &(&1.key == :object))
  defp apparatus_group, do: Enum.find(Layers.groups(), &(&1.key == :apparatus))

  # rastro só afeta vídeo (decaimento entre frames); num reprocesso de foto é
  # no-op, então some — não confunde com um controle que não faz nada.
  defp photo_reconvert?(%{"type" => "photo"}), do: true
  defp photo_reconvert?(_), do: false

  defp submit_label(nil), do: "Converter"
  defp submit_label(%{"status" => "new"}), do: "Processar agora"
  defp submit_label(_item), do: "Reprocessar agora"

  defp upload_error_label(:too_large), do: "arquivo grande demais (máx. 600 MB)"
  defp upload_error_label(:not_accepted), do: "formato não suportado"
  defp upload_error_label(:too_many_files), do: "envie 1 arquivo por vez"
  defp upload_error_label(other), do: inspect(other)
end
