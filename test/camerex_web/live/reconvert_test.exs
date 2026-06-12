defmodule CamerexWeb.ReconvertTest do
  use CamerexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    prev = Application.fetch_env!(:camerex, :workspace_root)
    Application.put_env(:camerex, :workspace_root, tmp)
    File.mkdir_p!(Path.join(tmp, "items"))
    on_exit(fn -> Application.put_env(:camerex, :workspace_root, prev) end)
    :ok
  end

  describe "ItemLive.reconvert_query/1" do
    test "monta a query a partir do manifest, descartando chaves ausentes" do
      manifest = %{
        "id" => "20260612-101010-casal-miami-ab12",
        "preset" => "miami",
        "params" => %{"halo" => 0.8, "trail" => 0.5, "detail" => 0.3, "swap_sides" => true}
      }

      assert CamerexWeb.ItemLive.reconvert_query(manifest) == %{
               "source" => "20260612-101010-casal-miami-ab12",
               "preset" => "miami",
               "halo" => 0.8,
               "trail" => 0.5,
               "detail" => 0.3,
               "swap_sides" => true
             }
    end

    test "foto sem trail: a chave simplesmente não entra" do
      manifest = %{"id" => "x", "preset" => "ouro", "params" => %{"halo" => 0.6}}
      query = CamerexWeb.ItemLive.reconvert_query(manifest)
      refute Map.has_key?(query, "trail")
      assert query["preset"] == "ouro"
    end
  end

  describe "GalleryLive.parse_reconvert/1" do
    test "valida preset, faz parse e clamp dos floats e do booleano" do
      assert %{source: "abc", settings: settings} =
               CamerexWeb.GalleryLive.parse_reconvert(%{
                 "source" => "abc",
                 "preset" => "miami",
                 "halo" => "0.8",
                 "trail" => "2.0",
                 "detail" => "0.3",
                 "swap_sides" => "true"
               })

      assert settings.preset == "miami"
      assert settings.halo == 0.8
      # clamp no teto do contrato para rastro (r ∈ [0, 0.95])
      assert settings.trail == 0.95
      assert settings.detail == 0.3
      assert settings.swap_sides == true
    end

    test "ignora preset inexistente, números inválidos e booleano malformado" do
      assert %{source: nil, settings: settings} =
               CamerexWeb.GalleryLive.parse_reconvert(%{
                 "preset" => "nope",
                 "halo" => "abc",
                 "swap_sides" => "talvez"
               })

      assert settings == %{}
    end
  end

  defp write_test_photo!(path) do
    rgb = Nx.broadcast(Nx.u8(128), {16, 16, 3})
    mat = Evision.Mat.from_nx_2d(rgb)
    true = Evision.imwrite(path, mat)
  end

  defp create_done_item!(tmp) do
    src = Path.join(tmp, "foto.png")
    write_test_photo!(src)

    {:ok, id} =
      Camerex.Workspace.create_item(src, "foto.png", :photo, "miami", %{
        "halo" => 0.8,
        "trail" => 0.7,
        "detail" => 0.3,
        "swap_sides" => false,
        "model" => "u2net"
      })

    {:ok, _} =
      Camerex.Workspace.update_manifest(
        id,
        &Map.merge(&1, %{"status" => "done", "output_file" => "neon.png"})
      )

    id
  end

  describe "fluxo completo" do
    test "botão do ItemLive navega para a galeria com query pré-preenchida",
         %{conn: conn, tmp_dir: tmp} do
      id = create_done_item!(tmp)
      {:ok, view, _html} = live(conn, "/item/#{id}")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#reconvert-button") |> render_click()

      assert to =~ "source=#{id}"
      assert to =~ "preset=miami"
      assert to =~ "halo=0.8"
    end

    test "galeria com ?source= mostra o chip e aplica os ajustes",
         %{conn: conn, tmp_dir: tmp} do
      id = create_done_item!(tmp)

      {:ok, _view, html} =
        live(conn, "/?source=#{id}&preset=miami&halo=0.8&trail=0.7&detail=0.3&swap_sides=false")

      assert html =~ "reconvert-chip"
      assert html =~ "foto.png"
      # o slider de halo do painel reflete o valor da query
      assert html =~ ~s(value="0.8")
    end

    test "reconvert_submit cria item NOVO sem tocar no original",
         %{conn: conn, tmp_dir: tmp} do
      id = create_done_item!(tmp)
      {:ok, view, _html} = live(conn, "/?source=#{id}&preset=pulp&halo=0.9")

      view |> element("#reconvert-submit") |> render_click()

      ids = Camerex.Workspace.list_items() |> Enum.map(& &1["id"])
      assert length(ids) == 2

      [new_id] = ids -- [id]
      {:ok, source_manifest} = Camerex.Workspace.manifest(id)
      {:ok, new_manifest} = Camerex.Workspace.manifest(new_id)

      # original intacto
      assert source_manifest["preset"] == "miami"
      assert source_manifest["params"]["halo"] == 0.8
      # novo item com os ajustes e com cópia própria do arquivo de origem
      assert new_manifest["preset"] == "pulp"
      assert new_manifest["params"]["halo"] == 0.9
      assert File.exists?(Camerex.Workspace.item_path(new_id, new_manifest["original_file"]))
    end
  end
end
