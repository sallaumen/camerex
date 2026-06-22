defmodule CamerexWeb.UITest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias CamerexWeb.UI

  describe "btn/1" do
    test "primário: classes de variante/tamanho e renderiza <button>" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UI.btn variant="primary">processar</UI.btn>
        """)

      assert html =~ "cx-btn"
      assert html =~ "cx-btn-primary"
      assert html =~ "cx-btn-md"
      assert html =~ "processar"
      assert html =~ "<button"
    end

    test "loading desabilita e mostra spinner" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UI.btn variant="primary" loading>processar</UI.btn>
        """)

      assert html =~ "animate-spin"
      assert html =~ "disabled"
    end

    test "com navigate vira link <a>, não <button>" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UI.btn navigate="/">home</UI.btn>
        """)

      assert html =~ "<a"
      assert html =~ "cx-btn"
      refute html =~ "<button"
    end
  end

  describe "badge/1" do
    test "tone processing usa a classe pulsante" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UI.badge tone="processing">processando</UI.badge>
        """)

      assert html =~ "neon-badge"
      assert html =~ "badge-processing"
      assert html =~ "processando"
    end

    test "tone danger" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UI.badge tone="danger">falhou</UI.badge>
        """)

      assert html =~ "badge-failed"
    end
  end

  describe "card/1" do
    test "interativo usa neon-card sobre a surface" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UI.card interactive>conteúdo</UI.card>
        """)

      assert html =~ "neon-card"
      assert html =~ "bg-cx-surface"
      assert html =~ "conteúdo"
    end
  end

  describe "progress/1" do
    test "value vira role=progressbar, aria-valuenow e scaleX" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UI.progress value={50} />
        """)

      assert html =~ ~s(role="progressbar")
      assert html =~ ~s(aria-valuenow="50")
      assert html =~ "scaleX(0.5)"
    end

    test "done/total calcula a porcentagem" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UI.progress done={3} total={10} />
        """)

      assert html =~ ~s(aria-valuenow="30")
    end
  end

  describe "progress_pct/1 (função pura)" do
    test "value, done/total, clamps e fallback" do
      assert UI.progress_pct(%{value: 42}) == 42
      assert UI.progress_pct(%{done: 1, total: 4}) == 25
      assert UI.progress_pct(%{value: 150}) == 100
      assert UI.progress_pct(%{value: -5}) == 0
      assert UI.progress_pct(%{done: 5, total: 0}) == 0
      assert UI.progress_pct(%{foo: 1}) == 0
    end
  end

  describe "close_button/1" do
    test "tem aria-label acessível e variante ghost" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UI.close_button label="fechar" />
        """)

      assert html =~ ~s(aria-label="fechar")
      assert html =~ "cx-btn-ghost"
    end
  end

  describe "input/1 e select/1" do
    test "input usa cx-input e repassa placeholder" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UI.input name="q" placeholder="buscar" />
        """)

      assert html =~ "cx-input"
      assert html =~ ~s(placeholder="buscar")
    end

    test "select renderiza as options com a selecionada" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UI.select name="n" options={[{"um", 1}, {"dois", 2}]} value={2} />
        """)

      assert html =~ "cx-input"
      assert html =~ "<option"
      assert html =~ ">dois</option>"
      assert html =~ "selected"
      assert html =~ ~s(value="2")
    end
  end
end
