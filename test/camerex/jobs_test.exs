defmodule Camerex.JobsTest do
  use Camerex.WorkspaceCase

  alias Camerex.{Jobs, Workspace}

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

  test "concorrência default vem das Settings (3) e set_concurrency persiste", %{jobs: jobs} do
    assert %{concurrency: 3} = Jobs.state(jobs)

    assert :ok = Jobs.set_concurrency(2, jobs)
    assert %{concurrency: 2} = Jobs.state(jobs)
    assert Camerex.Settings.get("concurrency", 3) == 2

    # clamp 1..6
    assert :ok = Jobs.set_concurrency(99, jobs)
    assert %{concurrency: 6} = Jobs.state(jobs)
  end

  test "pool: com concorrência 2, dois jobs rodam juntos e o terceiro espera",
       %{jobs: jobs, tmp: tmp} do
    :ok = Jobs.set_concurrency(2, jobs)
    [a, b, c] = for _ <- 1..3, do: create_photo_item!(tmp)

    for id <- [a, b, c], do: :ok = Jobs.enqueue(id, jobs)

    assert_receive {:pipeline_started, ^a, pid_a}
    assert_receive {:pipeline_started, ^b, _pid_b}
    refute_receive {:pipeline_started, ^c, _}, 100

    state = Jobs.state(jobs)
    assert Enum.map(state.running, & &1.item_id) |> Enum.sort() == Enum.sort([a, b])
    assert state.queue == [c]

    send(pid_a, {:finish, :ok})
    assert_receive {:pipeline_started, ^c, pid_c}

    send(pid_c, {:finish, :ok})
  end

  test "fila FIFO com concorrência 1 (comportamento v1 preservado)", %{jobs: jobs, tmp: tmp} do
    :ok = Jobs.set_concurrency(1, jobs)
    :ok = Jobs.subscribe()
    a = create_photo_item!(tmp)
    b = create_photo_item!(tmp)

    :ok = Jobs.enqueue(a, jobs)
    :ok = Jobs.enqueue(b, jobs)

    assert_receive {:pipeline_started, ^a, pid_a}
    refute_receive {:pipeline_started, ^b, _}, 100
    assert {:ok, %{"status" => "processing"}} = Workspace.manifest(a)
    assert_receive {:jobs_changed}

    send(pid_a, {:finish, :ok})
    assert_receive {:pipeline_started, ^b, pid_b}
    send(pid_b, {:finish, :ok})

    wait_until(fn -> match?(%{running: [], queue: []}, Jobs.state(jobs)) end)
  end

  test "enqueue é idempotente para item na fila ou rodando", %{jobs: jobs, tmp: tmp} do
    :ok = Jobs.set_concurrency(1, jobs)
    a = create_photo_item!(tmp)
    b = create_photo_item!(tmp)

    :ok = Jobs.enqueue(a, jobs)
    assert_receive {:pipeline_started, ^a, pid_a}

    :ok = Jobs.enqueue(a, jobs)
    :ok = Jobs.enqueue(b, jobs)
    :ok = Jobs.enqueue(b, jobs)

    assert %{queue: [^b]} = Jobs.state(jobs)

    send(pid_a, {:finish, :ok})
    assert_receive {:pipeline_started, ^b, pid_b}
    refute_receive {:pipeline_started, ^a, _}, 100
    send(pid_b, {:finish, :ok})
  end

  test "DOWN anormal marca failed só o job certo e o pool continua",
       %{jobs: jobs, tmp: tmp} do
    :ok = Jobs.set_concurrency(2, jobs)
    a = create_photo_item!(tmp)
    b = create_photo_item!(tmp)

    :ok = Jobs.enqueue(a, jobs)
    :ok = Jobs.enqueue(b, jobs)
    assert_receive {:pipeline_started, ^a, pid_a}
    assert_receive {:pipeline_started, ^b, pid_b}

    send(pid_a, {:finish, :raise})

    wait_until(fn -> match?({:ok, %{"status" => "failed"}}, Workspace.manifest(a)) end)
    {:ok, m} = Workspace.manifest(a)
    assert m["error"] =~ "explodiu de propósito"

    # b continua vivo e termina normalmente
    assert {:ok, %{"status" => "processing"}} = Workspace.manifest(b)
    send(pid_b, {:finish, :ok})
    wait_until(fn -> match?({:ok, %{"status" => "done"}}, Workspace.manifest(b)) end)
  end

  test "progresso por job com throttle e eta independentes", %{jobs: jobs, tmp: tmp} do
    :ok = Jobs.set_concurrency(2, jobs)
    a = create_photo_item!(tmp)
    :ok = Jobs.subscribe(a)
    :ok = Jobs.enqueue(a, jobs)
    assert_receive {:pipeline_started, ^a, pid}

    send(pid, {:progress, 1, 10})
    assert_receive {:job_progress, ^a, %{done: 1, total: 10, eta_s: eta}}
    assert is_number(eta)

    send(pid, {:progress, 2, 10})
    refute_receive {:job_progress, ^a, %{done: 2}}, 150

    wait_until(fn ->
      Enum.any?(Jobs.state(jobs).running, &match?(%{progress: %{done: 2}}, &1))
    end)

    send(pid, {:progress, 10, 10})
    assert_receive {:job_progress, ^a, %{done: 10, total: 10}}

    send(pid, {:finish, :ok})
  end

  test "entrar em processing zera restos da conversão anterior", %{jobs: jobs, tmp: tmp} do
    :ok = Jobs.set_concurrency(1, jobs)
    id = create_photo_item!(tmp)

    {:ok, _} =
      Workspace.update_manifest(id, fn m ->
        Map.merge(m, %{
          "status" => "done",
          "media" => %{"width" => 1},
          "timings_ms" => %{"total" => 99, "per_frame_avg" => 9},
          "error" => "resto antigo"
        })
      end)

    :ok = Jobs.enqueue(id, jobs)
    assert_receive {:pipeline_started, ^id, pid}

    {:ok, m} = Workspace.manifest(id)
    assert m["status"] == "processing"
    assert m["media"] == nil
    assert m["error"] == nil
    assert m["timings_ms"] == %{"total" => nil, "per_frame_avg" => nil}

    send(pid, {:finish, :ok})
  end

  test "no boot, manifests presos em processing viram interrupted", %{tmp: tmp} do
    id = create_photo_item!(tmp, %{status: "processing"})

    start_supervised!(
      Supervisor.child_spec(
        {Jobs, name: :"jobs_boot_#{System.unique_integer([:positive])}"},
        id: :jobs_boot
      )
    )

    assert {:ok, %{"status" => "interrupted"}} = Workspace.manifest(id)
  end

  test "foto pequena real passa pelo pipeline de verdade até done", %{jobs: jobs, tmp: tmp} do
    Application.put_env(:camerex, :photo_pipeline, Camerex.Pipeline.Photo)
    id = create_photo_item!(tmp)

    :ok = Jobs.enqueue(id, jobs)

    wait_until(fn -> match?({:ok, %{"status" => "done"}}, Workspace.manifest(id)) end, 10_000)
    assert File.exists?(Workspace.item_path(id, "neon.png"))
  end
end
