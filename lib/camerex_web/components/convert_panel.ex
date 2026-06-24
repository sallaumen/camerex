defmodule CamerexWeb.ConvertPanel do
  @moduledoc """
  Painel direito de conversão: dropzone, cor por parte (pele, cabelo, roupa…),
  sliders, calibragem ao vivo (prévia que reage aos controles, com atalhos de
  aplicação em massa) e presets salvos do usuário. Em modo reprocesso
  (`reconvert_item`) o submit reaplica os ajustes ao item existente em vez de
  criar um novo.

  Os controles vêm do kit `CamerexWeb.UI` (`slider/1`, `toggle/1`, `swatch/1`,
  `section/1`) estilizado em `app.css` (`.cx-range`, `.cx-switch`, `.cx-swatch`)
  — nada de range/checkbox/color nativos do browser, que destoavam do tema.
  Textos seguem a convenção do tema: rótulo curto em maiúscula inicial + o
  detalhe num `title` (tooltip), em vez de parágrafos longos inline.
  """

  use Phoenix.Component

  import CamerexWeb.CoreComponents, only: [icon: 1]
  import CamerexWeb.UI

  alias Camerex.Parser.Layers
  alias Camerex.RenderParams
  alias Phoenix.LiveView.JS

  attr :uploads, :map, required: true

  attr :render_params, RenderParams,
    required: true,
    doc: "struct com todos os campos de render (halo, cores por camada, detecções, fill…)"

  attr :eyedrop_armed, :boolean, default: false, doc: "conta-gotas do cabelo armado?"
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
        <h2 class="font-serif text-lg font-medium">
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
              id="calib-img"
              src={@calib_url}
              data-role="calib-img"
              phx-hook="EyedropHair"
              data-armed={to_string(@eyedrop_armed)}
              alt="prévia ao vivo da calibragem"
              class={[
                "mx-auto max-h-[72vh] w-full rounded-lg object-contain",
                @eyedrop_armed && "cursor-crosshair"
              ]}
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
              <.slider
                name="halo"
                label="Halo"
                title="Brilho suave em volta do contorno neon."
                value={@render_params.halo}
                min={0.0}
                max={1.0}
              />
              <.slider
                name="bloom"
                label="Brilho atmosférico"
                title="Brilho difuso que vaza pela cena, como uma névoa de luz."
                value={@render_params.bloom}
                min={0.0}
                max={1.0}
              />
              <.slider
                :if={not photo_reconvert?(@reconvert_item)}
                name="trail"
                label="Rastro"
                title="Rastro do movimento entre quadros (aparece só no vídeo final)."
                value={@render_params.trail}
                min={0.0}
                max={0.95}
              />
              <.slider
                name="detail"
                label="Detalhe"
                title="Quão fino é o traço do contorno — mais detalhe, mais linhas."
                value={@render_params.detail}
                min={0.0}
                max={1.0}
                step="0.02"
              />
            </.section>

            <.section title="Cor por parte">
              <div id="layer-pickers" class="space-y-3">
                <div class="grid grid-cols-2 gap-x-4 gap-y-2.5">
                  <.swatch
                    :for={group <- base_groups()}
                    name={"layer_#{group.key}"}
                    value={Layers.hex(Map.get(@render_params.layer_colors, group.key, group.default))}
                    label={cap(group.label)}
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
                  Editar todas as cores como JSON
                </button>
              </div>
            </.section>

            <.section title="Camadas extras" class="space-y-4">
              <div class="space-y-2">
                <.toggle
                  id="object-toggle"
                  name="detect_object"
                  label="Objeto na mão"
                  title="Destaca o que a pessoa segura — instrumento, microfone — com um segundo modelo (U²-Net)."
                  checked={@render_params.detect_object}
                />
                <div :if={@render_params.detect_object} class="pl-12">
                  <.swatch
                    id="object-color"
                    name={"layer_#{object_group().key}"}
                    value={
                      Layers.hex(
                        Map.get(@render_params.layer_colors, :object, object_group().default)
                      )
                    }
                    label={cap(object_group().label)}
                    aria={"cor da camada #{object_group().label}"}
                  />
                </div>
              </div>

              <div class="space-y-2">
                <.toggle
                  id="aerial-toggle"
                  name="detect_aerial"
                  label="Acrobacia aérea (tecido)"
                  title="Destaca o tecido vertical (silk) que a pessoa escala, como uma camada própria."
                  checked={@render_params.detect_aerial}
                />
                <div :if={@render_params.detect_aerial} class="space-y-2 pl-12">
                  <label
                    id="aerial-photo-color"
                    title="A cor real do tecido na foto original, para o detector localizá-lo."
                    class="flex items-center gap-2.5 text-sm text-cx-text"
                  >
                    <input
                      type="color"
                      name="aerial_color"
                      value={Layers.hex(@render_params.aerial_color)}
                      phx-debounce="200"
                      aria-label="cor real do tecido na foto"
                      class="cx-swatch"
                    />
                    <span>Cor do tecido na foto</span>
                  </label>
                  <.slider
                    name="aerial_sensitivity"
                    label="Sensibilidade do tecido"
                    title="Mais alto pega mais tecido (e mais risco de mancha); mais baixo fica limpo. Tecido vívido sobre fundo da mesma cor pede valor baixo; tecido sutil sobre fundo limpo pede alto."
                    value={@render_params.aerial_sensitivity}
                    min={0.0}
                    max={1.0}
                  />
                  <.swatch
                    id="aerial-color"
                    name={"layer_#{apparatus_group().key}"}
                    value={
                      Layers.hex(
                        Map.get(@render_params.layer_colors, :apparatus, apparatus_group().default)
                      )
                    }
                    label={cap(apparatus_group().label)}
                    aria={"cor da camada #{apparatus_group().label}"}
                  />
                </div>
              </div>

              <div class="space-y-2">
                <.toggle
                  id="hair-toggle"
                  name="detect_hair"
                  label="Resgatar cabelo"
                  title="Quando o detector não acha a cabeça (pose aérea ou de costas), localiza o cabelo pela cor que você indicar."
                  checked={@render_params.detect_hair}
                />
                <div :if={@render_params.detect_hair} class="space-y-2 pl-12">
                  <label
                    id="hair-photo-color"
                    title="A cor real do cabelo na foto original, para o detector localizá-lo."
                    class="flex items-center gap-2.5 text-sm text-cx-text"
                  >
                    <input
                      type="color"
                      name="hair_color"
                      value={Layers.hex(@render_params.hair_color)}
                      phx-debounce="200"
                      aria-label="cor real do cabelo na foto"
                      class="cx-swatch"
                    />
                    <span>Cor do cabelo na foto</span>
                  </label>
                  <.btn
                    :if={@calib_url}
                    variant={if @eyedrop_armed, do: "primary", else: "secondary"}
                    size="sm"
                    phx-click="toggle_eyedrop"
                    title="Clique num ponto do cabelo na prévia para capturar a cor exata."
                  >
                    <.icon name="hero-eye-dropper" class="size-4" />
                    {if @eyedrop_armed, do: "Clique no cabelo na prévia…", else: "Pegar cor do cabelo"}
                  </.btn>
                  <.slider
                    name="hair_sensitivity"
                    label="Sensibilidade do cabelo"
                    title="Mais alto resgata mais cabelo (e mais risco de pegar fundo parecido); mais baixo fica conservador. Use quando a cabeça some em pose aérea ou de costas."
                    value={@render_params.hair_sensitivity}
                    min={0.0}
                    max={1.0}
                  />
                </div>
              </div>

              <div class="space-y-2">
                <.toggle
                  id="skin-toggle"
                  name="detect_skin"
                  label="Pele do torso nu"
                  title="Quando a pessoa está sem a parte de cima, re-rotula costas e tronco (que o detector pinta como roupa) de volta como pele, aprendendo a cor dos braços e pernas."
                  checked={@render_params.detect_skin}
                />
                <div :if={@render_params.detect_skin} class="space-y-2 pl-12">
                  <.slider
                    name="skin_sensitivity"
                    label="Sensibilidade da pele"
                    title="Mais alto re-rotula mais roupa como pele (risco de pegar a calça); mais baixo fica conservador. Só afeta poses sem top (costas/tronco à mostra)."
                    value={@render_params.skin_sensitivity}
                    min={0.0}
                    max={1.0}
                  />
                </div>
              </div>

              <div class="space-y-2">
                <.toggle
                  id="person-fill-toggle"
                  name="detect_person_fill"
                  label="Preencher silhueta (pose aérea)"
                  title="Em pose aérea/invertida o detector às vezes joga partes da pessoa no fundo e ela some; isto fecha esses buracos com uma silhueta robusta (BiRefNet). Pesado em vídeo (~5s/frame)."
                  checked={@render_params.detect_person_fill}
                />
              </div>

              <div :if={not video_reconvert?(@reconvert_item)} class="space-y-2">
                <.toggle
                  id="head-fusion-toggle"
                  name="detect_head_fusion"
                  label="Recuperar cabeça (pose aérea)"
                  title="Quando o cabelo/rosto somem em pose invertida, funde um segundo modelo (SCHP) em várias rotações para recuperá-los. Mais lento e só para foto."
                  checked={@render_params.detect_head_fusion}
                />
              </div>

              <div class="space-y-2">
                <.toggle
                  id="fill-toggle"
                  name="fill"
                  label="Preencher as partes"
                  title="Pinta o interior das partes detectadas, não apenas o contorno."
                  checked={@render_params.fill}
                />
                <div :if={@render_params.fill} class="space-y-3 pl-12">
                  <.slider
                    name="fill_color"
                    label="Opacidade da cor"
                    title="Quão sólida é a cor preenchida sobre cada parte."
                    value={@render_params.fill_color}
                    min={0.0}
                    max={1.0}
                  />
                  <.slider
                    name="fill_texture"
                    label="Textura da foto"
                    title="Quanto da textura da foto original aparece no preenchimento."
                    value={@render_params.fill_texture}
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
                  label="Opacidade do fundo"
                  title="A foto original aparece atenuada atrás do neon."
                  value={@render_params.bg_opacity}
                  min={0.0}
                  max={1.0}
                />
                <.toggle
                  id="transparent-toggle"
                  name="transparent_bg"
                  label="Fundo transparente"
                  title="Remove o fundo por completo. Disponível só para foto/PNG."
                  checked={@render_params.transparent_bg}
                />
              </div>

              <div class="space-y-2">
                <.toggle
                  id="floor-toggle"
                  name="floor"
                  label="Luz no chão"
                  title="Brilho refletido no chão, sob os pés."
                  checked={@render_params.floor}
                />
                <div :if={@render_params.floor} id="floor-controls" class="space-y-3 pl-12">
                  <.slider name="glow" label="Brilho" value={@render_params.glow} min={0.0} max={1.0} />
                  <.slider
                    name="spread"
                    label="Espalhamento"
                    value={@render_params.spread}
                    min={0.0}
                    max={1.0}
                  />
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
                title="Só importa para a biblioteca; processa quando você quiser."
              >
                Só importar
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

  # espelho de photo_reconvert?/1: true só ao reprocessar um vídeo existente. Usado p/
  # esconder camadas SÓ-FOTO (ex.: head_fusion, no-op por frame no vídeo). Numa conversão
  # nova (reconvert_item nil) é false — o upload ainda pode ser foto.
  defp video_reconvert?(%{"type" => "video"}), do: true
  defp video_reconvert?(_), do: false

  # maiúscula só na 1ª letra (preserva o resto — não baixa caixa como String.capitalize/1)
  defp cap(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp cap(other), do: other

  defp submit_label(nil), do: "Converter"
  defp submit_label(%{"status" => "new"}), do: "Processar agora"
  defp submit_label(_item), do: "Reprocessar agora"

  defp upload_error_label(:too_large), do: "arquivo grande demais (máx. 600 MB)"
  defp upload_error_label(:not_accepted), do: "formato não suportado"
  defp upload_error_label(:too_many_files), do: "envie 1 arquivo por vez"
  defp upload_error_label(other), do: inspect(other)
end
