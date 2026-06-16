defmodule Camerex.Pipeline.VideoTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Camerex.{Pipeline, Workspace}
  alias Camerex.Video.Probe

  setup %{tmp_dir: tmp_dir} do
    previous = Application.fetch_env!(:camerex, :workspace_root)
    Application.put_env(:camerex, :workspace_root, tmp_dir)
    on_exit(fn -> Application.put_env(:camerex, :workspace_root, previous) end)
    :ok
  end

  test "converte testsrc de ponta a ponta: progresso, thumbs, manifest done",
       %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "clip.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=1:size=64x48:rate=8 #{src})
      )

    params = %{
      "halo" => 0.6,
      "trail" => 0.7,
      "detail" => 0.5,
      "swap_sides" => false,
      "model" => "u2netp"
    }

    {:ok, id} = Workspace.create_item(src, "clip.mp4", :video, "forro-duotone", params)
    test_pid = self()

    assert :ok =
             Pipeline.Video.run(id, fn done, total ->
               send(test_pid, {:progress, done, total})
             end)

    # progresso por frame + chamada final done == total
    assert_received {:progress, 1, _}
    assert_received {:progress, 8, 8}

    {:ok, manifest} = Workspace.manifest(id)
    assert manifest["status"] == "done"
    assert manifest["output_file"] == "neon.mp4"

    assert manifest["media"] ==
             %{"width" => 640, "height" => 480, "frames" => 8, "fps" => 8.0, "duration_s" => 1.0}

    assert is_integer(manifest["timings_ms"]["total"]) and manifest["timings_ms"]["total"] > 0
    assert is_number(manifest["timings_ms"]["per_frame_avg"])
    assert is_binary(manifest["completed_at"])

    # arquivo final válido, dimensões pares e cadência on twos: 8 desenhos/s
    # da origem viram um container 16fps com cada desenho segurado 2 frames
    out_path = Workspace.item_path(id, "neon.mp4")
    assert File.exists?(out_path)
    assert {:ok, out_info} = Probe.probe(out_path)
    assert out_info.width == 640
    assert out_info.height == 480
    assert rem(out_info.height, 2) == 0
    assert out_info.fps == 16.0
    assert_in_delta out_info.nb_frames, 16, 1

    # thumbs do primeiro frame (original + neon)
    assert File.exists?(Workspace.item_path(id, "thumb.jpg"))
    assert File.exists?(Workspace.item_path(id, "thumb_neon.jpg"))
  end

  test "cor-por-parte: layered: true converte de ponta a ponta (parser por frame)",
       %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "clip.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=1:size=64x48:rate=8 #{src})
      )

    # mesma funcionalidade da foto: liga layered e escolhe a cor de um grupo
    params = %{
      "halo" => 0.6,
      "trail" => 0.5,
      "layered" => true,
      "layer_colors" => %{"clothing" => [0, 0, 255]}
    }

    {:ok, id} = Workspace.create_item(src, "clip.mp4", :video, "forro-teal", params)
    test_pid = self()

    assert :ok =
             Pipeline.Video.run(id, fn done, total ->
               send(test_pid, {:progress, done, total})
             end)

    assert_received {:progress, 8, 8}

    {:ok, manifest} = Workspace.manifest(id)
    assert manifest["status"] == "done"
    assert manifest["output_file"] == "neon.mp4"

    out_path = Workspace.item_path(id, "neon.mp4")
    assert File.exists?(out_path)
    assert {:ok, %{width: 640}} = Probe.probe(out_path)
  end

  test "arquivo corrompido: {:error, _} e manifest failed com mensagem",
       %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "clip.mp4")
    File.write!(src, "isto não é um vídeo")

    {:ok, id} = Workspace.create_item(src, "clip.mp4", :video, "forro-duotone", %{})

    assert {:error, _} = Pipeline.Video.run(id, fn _, _ -> :ok end)

    {:ok, manifest} = Workspace.manifest(id)
    assert manifest["status"] == "failed"
    assert is_binary(manifest["error"]) and manifest["error"] != ""
  end

  test "frame_concurrency não altera a saída: serial e paralelo dão bytes idênticos",
       %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "clip.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=1:size=64x48:rate=8 #{src})
      )

    serial = Path.join(tmp_dir, "serial.mp4")
    parallel = Path.join(tmp_dir, "parallel.mp4")
    opts = [preset: "forro-duotone", detail: 0.5, trail: 0.7, model: "u2netp"]

    assert :ok =
             Pipeline.Video.render_file(src, serial, [{:frame_concurrency, 1} | opts], fn _, _ ->
               :ok
             end)

    assert :ok =
             Pipeline.Video.render_file(src, parallel, [{:frame_concurrency, 4} | opts], fn _,
                                                                                            _ ->
               :ok
             end)

    # map paralelo + scan sequencial preservam a matemática E a ordem dos frames,
    # então o stream que chega ao encoder é o mesmo -> saída byte a byte igual
    assert File.read!(serial) == File.read!(parallel)
  end
end
