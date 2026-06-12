defmodule CamerexWeb.DoctorBannerTest do
  use CamerexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    prev = Application.fetch_env!(:camerex, :workspace_root)
    Application.put_env(:camerex, :workspace_root, tmp)
    File.mkdir_p!(Path.join(tmp, "items"))

    on_exit(fn ->
      Application.put_env(:camerex, :workspace_root, prev)
      Application.delete_env(:camerex, :doctor_result)
    end)

    :ok
  end

  test "sem problemas: banner não aparece", %{conn: conn} do
    Application.put_env(:camerex, :doctor_result, %{ffmpeg: :ok, models: :ok})
    {:ok, _view, html} = live(conn, "/")
    refute html =~ "doctor-banner"
  end

  test "com problemas: banner lista mensagens e comandos de correção copiáveis", %{conn: conn} do
    Application.put_env(:camerex, :doctor_result, %{
      ffmpeg: {:error, "ffmpeg e ffprobe não encontrado(s) no PATH"},
      models: {:error, "modelos ausentes ou corrompidos: u2net.onnx"}
    })

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "doctor-banner"
    assert html =~ "ffmpeg e ffprobe não encontrado(s) no PATH"
    assert html =~ "brew install ffmpeg"
    assert html =~ "modelos ausentes ou corrompidos: u2net.onnx"
    assert html =~ "mix camerex.setup"
  end

  test "só os modelos faltando: um único comando de correção", %{conn: conn} do
    Application.put_env(:camerex, :doctor_result, %{
      ffmpeg: :ok,
      models: {:error, "modelos ausentes ou corrompidos: u2netp.onnx"}
    })

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "mix camerex.setup"
    refute html =~ "brew install ffmpeg"
  end
end
