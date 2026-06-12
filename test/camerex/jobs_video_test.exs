defmodule Camerex.JobsVideoTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Camerex.{Jobs, Workspace}

  setup %{tmp_dir: tmp_dir} do
    previous = Application.fetch_env!(:camerex, :workspace_root)
    Application.put_env(:camerex, :workspace_root, tmp_dir)
    on_exit(fn -> Application.put_env(:camerex, :workspace_root, previous) end)

    src = Path.join(tmp_dir, "clip.mp4")

    # 2 s × 8 fps = 16 frames: tempo de processamento suficiente para
    # pelo menos um broadcast de progresso passar pelo throttle de 250 ms
    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=2:size=64x48:rate=8 #{src})
      )

    %{src: src}
  end

  test "vídeo enfileirado processa com progresso PubSub e manifest done", %{src: src} do
    params = %{
      "halo" => 0.6,
      "trail" => 0.7,
      "detail" => 0.5,
      "swap_sides" => false,
      "model" => "u2netp"
    }

    {:ok, id} = Workspace.create_item(src, "clip.mp4", :video, "forro-duotone", params)

    :ok = Jobs.subscribe(id)
    :ok = Jobs.subscribe()
    :ok = Jobs.enqueue(id)

    assert_receive {:job_progress, ^id, %{done: done, total: total, eta_s: _}}, 30_000
    assert done >= 1
    assert total >= done

    wait_until(
      fn -> match?({:ok, %{"status" => "done"}}, Workspace.manifest(id)) end,
      60_000
    )

    {:ok, manifest} = Workspace.manifest(id)
    assert manifest["output_file"] == "neon.mp4"
    assert manifest["media"]["frames"] == 16
    assert File.exists?(Workspace.item_path(id, "neon.mp4"))
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condição não satisfeita dentro do timeout")

      true ->
        Process.sleep(100)
        do_wait(fun, deadline)
    end
  end
end
