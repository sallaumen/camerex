defmodule Camerex.Jobs do
  @moduledoc """
  Fila FIFO de conversões: 1 job por vez (o pipeline é CPU-bound).

  O job roda via Task.Supervisor.async_nolink — um crash do pipeline não
  derruba este GenServer nem o app; o DOWN anormal é tratado aqui e vira
  manifest "failed". Eventos via PubSub Camerex.PubSub:

    "jobs"     → {:jobs_changed}
    "job:<id>" → {:job_progress, id, %{done, total, eta_s}}  (throttle ≥ 250ms)
  """
  use GenServer

  alias Camerex.Workspace

  @progress_throttle_ms 250

  ## API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec enqueue(String.t()) :: :ok
  def enqueue(item_id), do: enqueue(item_id, __MODULE__)

  @doc false
  def enqueue(item_id, server), do: GenServer.call(server, {:enqueue, item_id})

  @spec state() :: %{
          running:
            nil
            | %{
                item_id: String.t(),
                progress: %{
                  done: non_neg_integer(),
                  total: non_neg_integer(),
                  eta_s: number() | nil
                }
              },
          queue: [String.t()]
        }
  def state, do: state(__MODULE__)

  @doc false
  def state(server), do: GenServer.call(server, :state)

  @spec subscribe() :: :ok
  def subscribe, do: Phoenix.PubSub.subscribe(Camerex.PubSub, "jobs")

  @spec subscribe(String.t()) :: :ok
  def subscribe(item_id), do: Phoenix.PubSub.subscribe(Camerex.PubSub, "job:" <> item_id)

  ## Callbacks

  @impl true
  def init(_opts) do
    {:ok,
     %{
       queue: :queue.new(),
       running: nil,
       task: nil,
       started_at_ms: nil,
       last_broadcast_ms: nil
     }}
  end

  @impl true
  def handle_call({:enqueue, item_id}, _from, state) do
    state =
      %{state | queue: :queue.in(item_id, state.queue)}
      |> maybe_start_next()

    broadcast_jobs_changed()
    {:reply, :ok, state}
  end

  def handle_call(:state, _from, state) do
    {:reply, %{running: state.running, queue: :queue.to_list(state.queue)}, state}
  end

  @impl true
  # progresso enviado pelo callback do pipeline (roda no processo da Task)
  def handle_info({:progress, item_id, done, total}, %{running: %{item_id: item_id}} = state) do
    now = System.monotonic_time(:millisecond)
    progress = %{done: done, total: total, eta_s: eta_s(state.started_at_ms, now, done, total)}
    state = put_in(state.running.progress, progress)

    if done >= total or state.last_broadcast_ms == nil or
         now - state.last_broadcast_ms >= @progress_throttle_ms do
      Phoenix.PubSub.broadcast(
        Camerex.PubSub,
        "job:" <> item_id,
        {:job_progress, item_id, progress}
      )

      {:noreply, %{state | last_broadcast_ms: now}}
    else
      {:noreply, state}
    end
  end

  # Task terminou normalmente: o próprio pipeline já gravou "done"/"failed"
  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_current(state)}
  end

  # Task crashou (DOWN anormal): manifest "failed" com erro legível
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    mark_failed(state.running.item_id, reason)
    {:noreply, finish_current(state)}
  end

  # progresso atrasado de job já encerrado, DOWNs antigos etc.: ignorar
  def handle_info(_msg, state), do: {:noreply, state}

  ## Internas

  defp maybe_start_next(%{running: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, item_id}, rest} ->
        case Workspace.update_manifest(item_id, &Map.put(&1, "status", "processing")) do
          {:ok, manifest} ->
            start_job(%{state | queue: rest}, item_id, manifest)

          {:error, :not_found} ->
            # item apagado enquanto esperava na fila: segue para o próximo
            maybe_start_next(%{state | queue: rest})
        end

      {:empty, _} ->
        state
    end
  end

  defp maybe_start_next(state), do: state

  defp start_job(state, item_id, manifest) do
    server = self()
    pipeline = pipeline_for(manifest)

    task =
      Task.Supervisor.async_nolink(Camerex.TaskSupervisor, fn ->
        pipeline.run(item_id, fn done, total ->
          send(server, {:progress, item_id, done, total})
        end)
      end)

    %{
      state
      | running: %{item_id: item_id, progress: %{done: 0, total: 0, eta_s: nil}},
        task: task,
        started_at_ms: System.monotonic_time(:millisecond),
        last_broadcast_ms: nil
    }
  end

  defp finish_current(state) do
    state =
      %{state | running: nil, task: nil, started_at_ms: nil}
      |> maybe_start_next()

    broadcast_jobs_changed()
    state
  end

  # módulo do pipeline via config: os testes injetam um fake
  defp pipeline_for(%{"type" => "video"}),
    do: Application.get_env(:camerex, :video_pipeline, Camerex.Pipeline.Video)

  defp pipeline_for(_manifest),
    do: Application.get_env(:camerex, :photo_pipeline, Camerex.Pipeline.Photo)

  # eta = média do tempo/frame desde o início × frames restantes
  defp eta_s(_started, _now, 0, _total), do: nil
  defp eta_s(_started, _now, _done, 0), do: nil

  defp eta_s(started_ms, now_ms, done, total) do
    avg_ms = (now_ms - started_ms) / done
    Float.round(max(total - done, 0) * avg_ms / 1000, 1)
  end

  defp mark_failed(item_id, reason) do
    _ =
      Workspace.update_manifest(item_id, fn m ->
        if m["status"] in ["done", "failed"] do
          # o pipeline já gravou um desfecho (com mensagem melhor): preservar
          m
        else
          m |> Map.put("status", "failed") |> Map.put("error", error_message(reason))
        end
      end)

    :ok
  end

  defp error_message({%{__exception__: true} = e, _stacktrace}), do: Exception.message(e)
  defp error_message(reason), do: inspect(reason)

  defp broadcast_jobs_changed do
    Phoenix.PubSub.broadcast(Camerex.PubSub, "jobs", {:jobs_changed})
  end
end
