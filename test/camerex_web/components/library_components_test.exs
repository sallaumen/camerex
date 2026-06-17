defmodule CamerexWeb.LibraryComponentsTest do
  use ExUnit.Case, async: true

  import CamerexWeb.DetailPanel
  import CamerexWeb.LibraryComponents
  import Phoenix.LiveViewTest

  defp item(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "20260612-x-foto-ouro-ab12",
        "type" => "photo",
        "status" => "done",
        "original_filename" => "foto.png",
        "original_file" => "original.png",
        "output_file" => "neon.png",
        "folder" => "shows",
        "params" => %{"halo" => 0.6, "trail" => 0.7, "detail" => 0.5},
        "error" => nil
      },
      attrs
    )
  end

  describe "folder_tree/1" do
    test "raiz + pastas com contagens, atual destacada e indentação por nível" do
      tree = [%{path: "shows", count: 2}, %{path: "shows/2026", count: 1}]
      html = render_component(&folder_tree/1, tree: tree, current: "shows", root_count: 5)

      assert html =~ ~s(data-folder="")
      assert html =~ ~s(data-folder="shows")
      assert html =~ ~s(data-folder="shows/2026")
      assert html =~ "biblioteca"
      # contagens visíveis
      assert html =~ ">5<"
      assert html =~ ">2<"
    end
  end

  describe "breadcrumb/1" do
    test "segmentos clicáveis com paths acumulados" do
      html = render_component(&breadcrumb/1, folder: "shows/2026/junho")

      assert html =~ ~s(phx-value-folder="shows")
      assert html =~ ~s(phx-value-folder="shows/2026")
      assert html =~ ~s(phx-value-folder="shows/2026/junho")
    end
  end

  describe "item_card/1" do
    test "done: thumbs antes/depois, chips e checkbox" do
      html = render_component(&item_card/1, item: item(), selected: false)

      assert html =~ "thumb.jpg"
      assert html =~ "thumb_neon.jpg"
      assert html =~ ~s(data-role="status-chip")
      assert html =~ "foto"
      assert html =~ ~s(phx-click="toggle_select")
      assert html =~ ~s(phx-click="open_item")
    end

    test "processing: barra de progresso com dados" do
      html =
        render_component(&item_card/1,
          item: item(%{"status" => "processing"}),
          selected: true,
          progress: %{done: 3, total: 10, eta_s: 7.0}
        )

      assert html =~ ~s(data-role="job-progress")
      assert html =~ "3/10"
      assert html =~ "~7s"
      assert html =~ ~s(data-selected="true")
    end
  end

  describe "selection_bar/1" do
    test "ações em massa rotuladas + presets salvos no select" do
      html =
        render_component(&selection_bar/1,
          count: 4,
          user_presets: [%{"id" => "meu", "name" => "Meu Preset"}],
          folders: ["shows"]
        )

      assert html =~ "4 selecionado(s)"
      assert html =~ "processar com ajustes atuais"
      assert html =~ "Meu Preset"
      assert html =~ "mover para…"
      assert html =~ "duplicar"
      assert html =~ "apagar"
    end
  end

  describe "detail_panel/1 (botões SEMPRE com texto — fix do bug v1)" do
    test "foto done: antes/depois, params e ações rotuladas" do
      html = render_component(&detail_panel/1, item: item())

      assert html =~ ~s(id="before")
      assert html =~ ~s(id="after")
      assert html =~ "Baixar"
      assert html =~ "Reprocessar com ajustes"
      assert html =~ "Duplicar"
      assert html =~ "Apagar"
      assert html =~ "fechar"
    end

    test "vídeo: dois players" do
      html =
        render_component(&detail_panel/1,
          item: item(%{"type" => "video", "output_file" => "neon.mp4"})
        )

      assert html =~ ~s(data-role="video-original")
      assert html =~ ~s(data-role="video-neon")
    end

    test "failed: botão Tentar de novo e mensagem de erro" do
      html =
        render_component(&detail_panel/1,
          item: item(%{"status" => "failed", "error" => "deu ruim"})
        )

      assert html =~ "Tentar de novo"
      assert html =~ "deu ruim"
    end

    test "todo botão do painel tem texto visível (auditoria do bug v1)" do
      html =
        render_component(&detail_panel/1, item: item(%{"status" => "failed", "error" => "x"}))

      buttons = Regex.scan(~r/<button[^>]*>(.*?)<\/button>/s, html, capture: :all_but_first)

      for [inner] <- buttons do
        text = inner |> String.replace(~r/<[^>]+>/, "") |> String.trim()
        assert text != "", "botão sem texto visível: #{inspect(inner)}"
      end
    end
  end
end
