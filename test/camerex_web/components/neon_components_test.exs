defmodule CamerexWeb.NeonComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import CamerexWeb.NeonComponents

  alias Camerex.Neon.Palette

  test "status_badge/1 mapeia cada status para rótulo e classe próprios" do
    expected = %{
      "queued" => {"na fila", "badge-queued"},
      "processing" => {"processando", "badge-processing"},
      "done" => {"pronto", "badge-done"},
      "failed" => {"falhou", "badge-failed"},
      "interrupted" => {"interrompido", "badge-interrupted"}
    }

    for {status, {label, class}} <- expected do
      html = render_component(&status_badge/1, status: status)
      assert html =~ label
      assert html =~ class
      assert html =~ ~s(data-status="#{status}")
    end
  end

  test "status desconhecido cai no badge neutro" do
    html = render_component(&status_badge/1, status: "whatever")
    assert html =~ "badge-queued"
  end

  test "preset_swatch/1 usa as cores exatas da Palette no glow e no fundo" do
    mono = Palette.get("ouro")
    html = render_component(&preset_swatch/1, preset: mono, selected: false)
    assert html =~ ~s(data-swatch="ouro")
    assert html =~ "--glow:#FFD166"
    assert html =~ "background:#FFD166"

    duo = Palette.get("miami")
    html = render_component(&preset_swatch/1, preset: duo, selected: true)
    assert html =~ "linear-gradient(90deg,#FF2E97,#00C2FF)"
    assert html =~ "neon-swatch-selected"
  end
end
