defmodule CamerexWeb.ItemLiveTest do
  use CamerexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  import Camerex.WorkspaceCase

  alias Camerex.Workspace

  setup :override_workspace_root

  defmodule PipelineNoop do
    def run(_item_id, _progress_cb), do: :ok
  end

  defp seed_done_item!(tmp) do
    id = create_photo_item!(tmp)

    {:ok, _} =
      Workspace.update_manifest(id, fn m ->
        m |> Map.put("status", "done") |> Map.put("output_file", "neon.png")
      end)

    File.write!(Workspace.item_path(id, "neon.png"), <<137, 80, 78, 71>>)
    id
  end

  test "item done mostra antes/depois, params e download", %{conn: conn, tmp: tmp} do
    id = seed_done_item!(tmp)

    {:ok, view, html} = live(conn, ~p"/item/#{id}")

    assert has_element?(view, "#before[src='/media/items/#{id}/original.png']")
    assert has_element?(view, "#after[src='/media/items/#{id}/neon.png']")
    assert has_element?(view, "#download[href='/media/items/#{id}/neon.png']")
    assert html =~ "forro-teal"
    assert has_element?(view, "#params", "0.6")
    refute has_element?(view, "#retry")
  end

  test "apagar tem data-confirm, remove o item e volta para a galeria", %{conn: conn, tmp: tmp} do
    id = seed_done_item!(tmp)
    {:ok, view, _html} = live(conn, ~p"/item/#{id}")

    assert has_element?(view, "#delete[data-confirm]")

    assert {:error, {:live_redirect, %{to: "/"}}} =
             view |> element("#delete") |> render_click()

    assert Workspace.manifest(id) == {:error, :not_found}
  end

  test "tentar de novo re-enfileira item failed", %{conn: conn, tmp: tmp} do
    Application.put_env(:camerex, :photo_pipeline, PipelineNoop)
    on_exit(fn -> Application.delete_env(:camerex, :photo_pipeline) end)

    id = create_photo_item!(tmp, %{status: "failed"})
    {:ok, view, _html} = live(conn, ~p"/item/#{id}")

    view |> element("#retry") |> render_click()

    {:ok, m} = Workspace.manifest(id)
    assert m["status"] in ["queued", "processing"]
    assert m["error"] == nil
  end

  test "id inexistente redireciona para a galeria", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/item/nao-existe")
  end
end
