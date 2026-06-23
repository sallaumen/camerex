defmodule CamerexWeb.JobsIndicatorTest do
  use CamerexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  import Camerex.WorkspaceCase

  alias Camerex.Jobs
  alias CamerexWeb.LibraryComponents

  setup :override_workspace_root

  # pipeline que trava em "processing" até receber :release (sem poluir a pool)
  defmodule BlockingPipeline do
    def run(_item_id, _cb) do
      send(Application.get_env(:camerex, :test_pid), {:job_pid, self()})

      receive do
        :release -> :ok
      after
        15_000 -> :ok
      end
    end
  end

  describe "jobs_indicator (componente)" do
    test "mostra contagens + frames + ETA quando há jobs" do
      html =
        render_component(&LibraryComponents.jobs_indicator/1,
          summary: %{processing: 1, queued: 2, done: 340, total: 622, eta_s: 180.0, paused: false}
        )

      assert html =~ "jobs-indicator"
      assert html =~ "1 processando"
      assert html =~ "2 na fila"
      assert html =~ "340/622"
      assert html =~ "3min"
    end

    test "ETA em segundos quando < 1min" do
      html =
        render_component(&LibraryComponents.jobs_indicator/1,
          summary: %{processing: 1, queued: 0, done: 10, total: 20, eta_s: 45.0, paused: false}
        )

      assert html =~ "~45s"
      refute html =~ "na fila"
    end

    test "some quando ocioso (0 processando, 0 na fila)" do
      html =
        render_component(&LibraryComponents.jobs_indicator/1,
          summary: %{processing: 0, queued: 0, done: 0, total: 0, eta_s: nil, paused: false}
        )

      refute html =~ "jobs-indicator"
    end

    test "oferece pausar quando rodando; retomar + 'pausada' quando pausado" do
      rodando =
        render_component(&LibraryComponents.jobs_indicator/1,
          summary: %{processing: 1, queued: 2, done: 0, total: 0, eta_s: nil, paused: false}
        )

      assert rodando =~ "toggle_queue_pause"
      assert rodando =~ "pausar"
      refute rodando =~ "pausada"

      pausado =
        render_component(&LibraryComponents.jobs_indicator/1,
          summary: %{processing: 0, queued: 2, done: 0, total: 0, eta_s: nil, paused: true}
        )

      assert pausado =~ "retomar"
      assert pausado =~ "pausada"
    end
  end

  test "indicador GLOBAL aparece quando um job está processando", %{conn: conn, tmp: tmp} do
    Application.put_env(:camerex, :test_pid, self())
    Application.put_env(:camerex, :photo_pipeline, BlockingPipeline)
    on_exit(fn -> Application.delete_env(:camerex, :photo_pipeline) end)

    id = create_photo_item!(tmp, %{status: "done"})

    {:ok, view, _} = live(conn, "/")
    refute has_element?(view, "#jobs-indicator")

    # enfileira: o job começa, trava em "processing", e dispara {:jobs_changed}
    :ok = Jobs.enqueue(id)
    assert_receive {:job_pid, pid}, 2000

    assert has_element?(view, "#jobs-indicator", "processando")

    send(pid, :release)
  end
end
