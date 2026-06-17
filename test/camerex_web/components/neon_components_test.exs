defmodule CamerexWeb.NeonComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import CamerexWeb.NeonComponents

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
end
