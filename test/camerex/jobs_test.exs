defmodule Camerex.JobsTest do
  use Camerex.WorkspaceCase

  alias Camerex.Jobs
  alias Camerex.Workspace

  defmodule FakePipeline do
    def run(item_id, progress_cb) do
      test_pid = Application.fetch_env!(:camerex, :fake_pipeline_test_pid)
      send(test_pid, {:pipeline_started, item_id, self()})
      loop(item_id, progress_cb)
    end

    defp loop(item_id, progress_cb) do
      receive do
        {:progress, done, total} ->
          progress_cb.(done, total)
          loop(item_id, progress_cb)

        {:finish, :ok} ->
          {:ok, _} = Workspace.update_manifest(item_id, &Map.put(&1, "status", "done"))
          :ok

        {:finish, :raise} ->
          raise "explodiu de propósito"
      end
    end
  end

  setup do
    Application.put_env(:camerex, :photo_pipeline, FakePipeline)
    Application.put_env(:camerex, :fake_pipeline_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:camerex, :photo_pipeline)
      Application.delete_env(:camerex, :fake_pipeline_test_pid)
    end)

    # Na Task 3.3 o Task.Supervisor entra na árvore do app; até lá (e em
    # qualquer ordem de execução) garantimos um aqui.
    unless Process.whereis(Camerex.TaskSupervisor) do
      start_supervised!({Task.Supervisor, name: Camerex.TaskSupervisor})
    end

    jobs = start_supervised!({Jobs, name: :"jobs_#{System.unique_integer([:positive])}"})
    %{jobs: jobs}
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condição não satisfeita a tempo")

      true ->
        Process.sleep(20)
        do_wait(fun, deadline)
    end
  end

  test "executa 1 job por vez, em ordem FIFO", %{jobs: jobs, tmp: tmp} do
    :ok = Jobs.subscribe()
    a = create_photo_item!(tmp)
    b = create_photo_item!(tmp)

    :ok = Jobs.enqueue(a, jobs)
    :ok = Jobs.enqueue(b, jobs)

    assert_receive {:pipeline_started, ^a, pid_a}
    refute_receive {:pipeline_started, ^b, _}, 100

    assert %{running: %{item_id: ^a}, queue: [^b]} = Jobs.state(jobs)
    assert {:ok, %{"status" => "processing"}} = Workspace.manifest(a)
    assert {:ok, %{"status" => "queued"}} = Workspace.manifest(b)
    assert_receive {:jobs_changed}

    send(pid_a, {:finish, :ok})
    assert_receive {:pipeline_started, ^b, pid_b}
    assert {:ok, %{"status" => "done"}} = Workspace.manifest(a)

    send(pid_b, {:finish, :ok})
    wait_until(fn -> Jobs.state(jobs) == %{running: nil, queue: []} end)
  end

  test "DOWN anormal marca manifest failed e a fila continua", %{jobs: jobs, tmp: tmp} do
    a = create_photo_item!(tmp)
    b = create_photo_item!(tmp)

    :ok = Jobs.enqueue(a, jobs)
    :ok = Jobs.enqueue(b, jobs)

    assert_receive {:pipeline_started, ^a, pid_a}
    send(pid_a, {:finish, :raise})

    assert_receive {:pipeline_started, ^b, pid_b}
    assert {:ok, m} = Workspace.manifest(a)
    assert m["status"] == "failed"
    assert m["error"] =~ "explodiu de propósito"

    send(pid_b, {:finish, :ok})
  end

  test "broadcast de progresso com throttle de 250ms e eta", %{jobs: jobs, tmp: tmp} do
    a = create_photo_item!(tmp)
    :ok = Jobs.subscribe(a)
    :ok = Jobs.enqueue(a, jobs)
    assert_receive {:pipeline_started, ^a, pid}

    send(pid, {:progress, 1, 10})
    assert_receive {:job_progress, ^a, %{done: 1, total: 10, eta_s: eta}}
    assert is_number(eta)

    # segundo progresso dentro da janela de 250ms: broadcast suprimido...
    send(pid, {:progress, 2, 10})
    refute_receive {:job_progress, ^a, %{done: 2}}, 150

    # ...mas o estado interno sempre atualiza
    wait_until(fn -> match?(%{running: %{progress: %{done: 2}}}, Jobs.state(jobs)) end)

    # done == total fura o throttle (a mensagem final sempre sai)
    send(pid, {:progress, 10, 10})
    assert_receive {:job_progress, ^a, %{done: 10, total: 10}}

    send(pid, {:finish, :ok})
  end

  test "no boot, manifests presos em processing viram interrupted", %{tmp: tmp} do
    id = create_photo_item!(tmp, %{status: "processing"})

    # segunda instância no mesmo teste: precisa de child id próprio, senão
    # colide com o id default (Camerex.Jobs) da instância do setup
    start_supervised!(
      Supervisor.child_spec(
        {Jobs, name: :"jobs_boot_#{System.unique_integer([:positive])}"},
        id: :jobs_boot
      )
    )

    assert {:ok, %{"status" => "interrupted"}} = Workspace.manifest(id)
  end

  test "foto pequena real passa pelo pipeline de verdade até done", %{jobs: jobs, tmp: tmp} do
    # usa o Camerex.Pipeline.Photo real; o segmenter de teste é o Fixture
    Application.put_env(:camerex, :photo_pipeline, Camerex.Pipeline.Photo)
    id = create_photo_item!(tmp)

    :ok = Jobs.enqueue(id, jobs)

    wait_until(fn -> match?({:ok, %{"status" => "done"}}, Workspace.manifest(id)) end, 10_000)
    assert File.exists?(Workspace.item_path(id, "neon.png"))
  end
end
