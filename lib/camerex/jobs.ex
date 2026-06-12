defmodule Camerex.Jobs do
  @moduledoc """
  Pool de conversões com fila FIFO: até `concurrency` jobs simultâneos
  (default 3, ajustável 1..6 e persistido nas Settings).

  Cada job roda via Task.Supervisor.async_nolink — um crash do pipeline não
  derruba este GenServer nem o app; o DOWN anormal é tratado por ref e vira
  manifest "failed". Eventos via PubSub Camerex.PubSub:

    "jobs"     → {:jobs_changed}
    "job:<id>" → {:job_progress, id, %{done, total, eta_s}}  (throttle ≥ 250ms por job)
  """
  use GenServer

  alias Camerex.{Settings, Workspace}

  @progress_throttle_ms 250
  @default_concurrency 3
  @concurrency_range 1..6

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
          running: [%{item_id: String.t(), progress: map()}],
          queue: [String.t()],
          concurrency: pos_integer()
        }
  def state, do: state(__MODULE__)

  @doc false
  def state(server), do: GenServer.call(server, :state)

  @doc "Ajusta o tamanho do pool (1..6, com clamp) e persiste nas Settings."
  @spec set_concurrency(integer()) :: :ok
  def set_concurrency(n), do: set_concurrency(n, __MODULE__)

  @doc false
  def set_concurrency(n, server), do: GenServer.call(server, {:set_concurrency, n})

  @spec subscribe() :: :ok
  def subscribe, do: Phoenix.PubSub.subscribe(Camerex.PubSub, "jobs")

  @spec subscribe(String.t()) :: :ok
  def subscribe(item_id), do: Phoenix.PubSub.subscribe(Camerex.PubSub, "job:" <> item_id)

  ## Callbacks

  @impl true
  def init(_opts) do
    :ok = Workspace.mark_interrupted_on_boot()

    {:ok,
     %{
       queue: :queue.new(),
       # ref da Task => %{item_id, progress, started_at_ms, last_broadcast_ms}
       running: %{},
       concurrency: Settings.get("concurrency", @default_concurrency)
     }}
  end

  @impl true
  def handle_call({:enqueue, item_id}, _from, state) do
    if known?(state, item_id) do
      {:reply, :ok, state}
    else
      state =
        %{state | queue: :queue.in(item_id, state.queue)}
        |> fill_pool()

      broadcast_jobs_changed()
      {:reply, :ok, state}
    end
  end

  def handle_call(:state, _from, state) do
    running =
      state.running
      |> Map.values()
      |> Enum.map(&Map.take(&1, [:item_id, :progress]))

    {:reply,
     %{running: running, queue: :queue.to_list(state.queue), concurrency: state.concurrency},
     state}
  end

  def handle_call({:set_concurrency, n}, _from, state) do
    concurrency = n |> max(@concurrency_range.first) |> min(@concurrency_range.last)
    :ok = Settings.put("concurrency", concurrency)

    state = %{state | concurrency: concurrency} |> fill_pool()
    broadcast_jobs_changed()
    {:reply, :ok, state}
  end

  @impl true
  # progresso enviado pelo callback do pipeline (roda no processo da Task)
  def handle_info({:progress, item_id, done, total}, state) do
    case find_ref(state, item_id) do
      nil -> {:noreply, state}
      ref -> {:noreply, update_progress(state, ref, done, total)}
    end
  end

  # Task terminou normalmente: o próprio pipeline já gravou "done"/"failed"
  def handle_info({ref, _result}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_job(state, ref)}
  end

  # Task crashou (DOWN anormal): manifest "failed" com erro legível
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.running, ref) do
    mark_failed(state.running[ref].item_id, reason)
    {:noreply, finish_job(state, ref)}
  end

  # progresso atrasado de job já encerrado, DOWNs antigos etc.: ignorar
  def handle_info(_msg, state), do: {:noreply, state}

  ## Internas

  defp known?(state, item_id) do
    item_id in :queue.to_list(state.queue) or find_ref(state, item_id) != nil
  end

  defp find_ref(state, item_id) do
    Enum.find_value(state.running, fn {ref, job} ->
      if job.item_id == item_id, do: ref
    end)
  end

  # preenche o pool até a concorrência configurada
  defp fill_pool(state) do
    if map_size(state.running) < state.concurrency do
      case :queue.out(state.queue) do
        {{:value, item_id}, rest} ->
          %{state | queue: rest}
          |> start_job(item_id)
          |> fill_pool()

        {:empty, _} ->
          state
      end
    else
      state
    end
  end

  defp start_job(state, item_id) do
    case Workspace.update_manifest(item_id, &mark_processing/1) do
      {:ok, manifest} ->
        server = self()
        pipeline = pipeline_for(manifest)

        task =
          Task.Supervisor.async_nolink(Camerex.TaskSupervisor, fn ->
            pipeline.run(item_id, fn done, total ->
              send(server, {:progress, item_id, done, total})
            end)
          end)

        job = %{
          item_id: item_id,
          progress: %{done: 0, total: 0, eta_s: nil},
          started_at_ms: System.monotonic_time(:millisecond),
          last_broadcast_ms: nil
        }

        put_in(state.running[task.ref], job)

      {:error, :not_found} ->
        # item apagado enquanto esperava na fila: segue para o próximo
        state
    end
  end

  # entrar em processing zera restos da conversão anterior (overwrite limpo)
  defp mark_processing(manifest) do
    Map.merge(manifest, %{
      "status" => "processing",
      "error" => nil,
      "completed_at" => nil,
      "media" => nil,
      "timings_ms" => %{"total" => nil, "per_frame_avg" => nil}
    })
  end

  defp finish_job(state, ref) do
    state = %{state | running: Map.delete(state.running, ref)} |> fill_pool()
    broadcast_jobs_changed()
    state
  end

  defp update_progress(state, ref, done, total) do
    now = System.monotonic_time(:millisecond)
    job = state.running[ref]
    progress = %{done: done, total: total, eta_s: eta_s(job.started_at_ms, now, done, total)}
    job = %{job | progress: progress}

    if done >= total or job.last_broadcast_ms == nil or
         now - job.last_broadcast_ms >= @progress_throttle_ms do
      Phoenix.PubSub.broadcast(
        Camerex.PubSub,
        "job:" <> job.item_id,
        {:job_progress, job.item_id, progress}
      )

      put_in(state.running[ref], %{job | last_broadcast_ms: now})
    else
      put_in(state.running[ref], job)
    end
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
