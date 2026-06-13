defmodule CamerexWeb.ConvertPanel do
  @moduledoc """
  Painel direito de conversão: dropzone, presets de cor, sliders, calibragem
  ao vivo (prévia que reage aos controles, com atalhos de aplicação em massa)
  e presets salvos do usuário. Em modo reprocesso (`reconvert_item`) o submit
  reaplica os ajustes ao item existente em vez de criar um novo.
  """

  use Phoenix.Component

  import CamerexWeb.NeonComponents

  alias Camerex.Neon.Palette
  alias Phoenix.LiveView.JS

  attr :uploads, :map, required: true
  attr :presets, :list, required: true
  attr :preset_id, :string, required: true
  attr :halo, :float, required: true
  attr :trail, :float, required: true
  attr :detail, :float, required: true
  attr :swap_sides, :boolean, required: true
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
    <section id="convert-panel" class="space-y-4">
      <div
        :if={@reconvert_item}
        id="reconvert-chip"
        class="flex flex-wrap items-center gap-2 rounded-lg border border-cx-teal bg-cx-bg p-2 text-sm"
      >
        <span>
          {if @reconvert_item["status"] == "new", do: "processando", else: "reprocessando"}
          <strong>{@reconvert_item["original_filename"]}</strong>
        </span>
        <button type="button" class="text-cx-text-dim underline" phx-click="reconvert_cancel">
          cancelar
        </button>
      </div>

      <div :if={@calib} id="calib-preview" class="rounded-lg border border-cx-border bg-cx-bg p-2">
        <p :if={@calib == :preparing and @calib_url == nil} class="text-sm text-cx-text-dim">
          preparando prévia…
        </p>
        <img
          :if={@calib_url}
          src={@calib_url}
          data-role="calib-img"
          alt="prévia ao vivo da calibragem"
          class="w-full rounded"
        />
        <p :if={@calib_error} class="mt-1 text-sm text-cx-orange">
          prévia falhou: {@calib_error}
        </p>
        <p class="mt-1 text-xs text-cx-text-dim">
          prévia ao vivo · o rastro só aparece no vídeo final
        </p>
      </div>

      <form id="convert-form" phx-submit="convert" phx-change="validate">
        <div
          :if={@reconvert_item == nil}
          id="dropzone"
          phx-drop-target={@uploads.media.ref}
          class="rounded border border-dashed border-cx-border p-3"
        >
          <.live_file_input upload={@uploads.media} />
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

        <fieldset id="preset-swatches" class="mt-4 flex flex-wrap items-center gap-3">
          <.preset_swatch
            :for={preset <- @presets}
            preset={preset}
            selected={preset.id == @preset_id}
            phx-click="select_preset"
            phx-value-id={preset.id}
          />
          <span class="text-xs text-cx-text-dim">
            {(Palette.get(@preset_id) || %{name: @preset_id}).name}
          </span>
        </fieldset>

        <div class="mt-4 space-y-3 text-sm">
          <label class="block">
            halo ({@halo})
            <input
              type="range"
              name="halo"
              min="0"
              max="1"
              step="0.05"
              value={@halo}
              phx-debounce="150"
              class="w-full"
            />
          </label>
          <label class="block">
            rastro ({@trail})
            <input
              type="range"
              name="trail"
              min="0"
              max="0.95"
              step="0.05"
              value={@trail}
              phx-debounce="150"
              class="w-full"
            />
          </label>
          <label class="block">
            detalhe ({@detail})
            <input
              type="range"
              name="detail"
              min="0"
              max="1"
              step="0.05"
              value={@detail}
              phx-debounce="150"
              class="w-full"
            />
          </label>
        </div>

        <label :if={duotone?(@preset_id)} id="swap-sides" class="mt-3 flex items-center gap-2 text-sm">
          <input type="hidden" name="swap_sides" value="false" />
          <input type="checkbox" name="swap_sides" value="true" checked={@swap_sides} />
          inverter lados
        </label>

        <button
          type="submit"
          id="convert-submit"
          class="mt-4 rounded bg-cx-teal px-4 py-2 font-medium text-cx-bg"
        >
          {submit_label(@reconvert_item)}
        </button>
      </form>

      <div :if={@calib} id="calib-apply" class="mt-3 flex flex-wrap gap-2 text-sm">
        <button
          :if={@folder_count > 0}
          type="button"
          id="apply-folder"
          phx-click="apply_folder"
          data-confirm={"Aplicar estes ajustes em #{@folder_count} item(ns) desta pasta?"}
          class="rounded border border-cx-border px-3 py-1.5 hover:border-cx-teal"
        >
          Aplicar nesta pasta ({@folder_count})
        </button>
        <button
          :if={@selected_count > 0}
          type="button"
          id="apply-selection"
          phx-click="apply_selection"
          class="rounded border border-cx-border px-3 py-1.5 hover:border-cx-teal"
        >
          Aplicar na seleção ({@selected_count})
        </button>
      </div>

      <div id="user-presets" class="border-t border-cx-border pt-3">
        <p class="mb-2 text-xs uppercase tracking-wide text-cx-text-dim">meus presets</p>

        <form id="save-preset-form" phx-submit="save_preset" class="flex items-center gap-2">
          <input
            type="text"
            name="name"
            value={@preset_name}
            placeholder="nome do preset…"
            class="w-full rounded border border-cx-border bg-cx-bg px-2 py-1.5 text-sm"
          />
          <button
            type="submit"
            class="whitespace-nowrap rounded border border-cx-teal px-3 py-1.5 text-sm text-cx-teal"
          >
            salvar ajustes
          </button>
        </form>

        <ul :if={@user_presets != []} class="mt-2 space-y-1 text-sm">
          <li :for={p <- @user_presets} class="flex items-center gap-2" data-user-preset={p["id"]}>
            <button
              type="button"
              phx-click="apply_preset"
              phx-value-id={p["id"]}
              class="flex-1 truncate rounded px-2 py-1 text-left hover:bg-cx-bg"
              title={"aplicar #{p["name"]}"}
            >
              {p["name"]}
              <span class="text-xs text-cx-text-dim">· {p["preset"]}</span>
            </button>
            <button
              type="button"
              phx-click={JS.push("delete_preset", value: %{id: p["id"]})}
              data-confirm={"Apagar o preset #{p["name"]}?"}
              aria-label={"apagar preset #{p["name"]}"}
              class="text-cx-text-dim hover:text-red-300"
            >
              ✕
            </button>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  defp duotone?(preset_id) do
    match?(%{mode: :duotone}, Palette.get(preset_id))
  end

  defp submit_label(nil), do: "Converter"
  defp submit_label(%{"status" => "new"}), do: "Processar agora"
  defp submit_label(_item), do: "Reprocessar agora"

  defp upload_error_label(:too_large), do: "arquivo grande demais (máx. 600 MB)"
  defp upload_error_label(:not_accepted), do: "formato não suportado"
  defp upload_error_label(:too_many_files), do: "envie 1 arquivo por vez"
  defp upload_error_label(other), do: inspect(other)
end
