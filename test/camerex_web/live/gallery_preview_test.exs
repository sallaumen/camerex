defmodule CamerexWeb.GalleryPreviewTest do
  use CamerexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.fetch_env!(:camerex, :workspace_root)
    Application.put_env(:camerex, :workspace_root, tmp_dir)
    File.mkdir_p!(Path.join(tmp_dir, "items"))
    File.mkdir_p!(Path.join(tmp_dir, "tmp"))
    on_exit(fn -> Application.put_env(:camerex, :workspace_root, previous) end)

    mp4 = Path.join(tmp_dir, "clip.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=1:size=64x48:rate=8 #{mp4})
      )

    jpg = Path.join(tmp_dir, "foto.jpg")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=1:size=64x48:rate=1 -frames:v 1 #{jpg})
      )

    %{mp4: mp4, jpg: jpg}
  end

  test "upload de vídeo mostra botão de prévia que gera <img> com data URL",
       %{conn: conn, mp4: mp4} do
    {:ok, lv, _html} = live(conn, "/")

    lv
    |> file_input("#convert-form", :media, [
      %{name: "clip.mp4", content: File.read!(mp4), type: "video/mp4"}
    ])
    |> render_upload("clip.mp4")

    assert render(lv) =~ ~s(data-role="preview-button")

    html = lv |> element(~s([data-role="preview-button"])) |> render_click()
    assert html =~ "data:image/png;base64,"
  end

  test "upload de foto não mostra botão de prévia", %{conn: conn, jpg: jpg} do
    {:ok, lv, _html} = live(conn, "/")

    lv
    |> file_input("#convert-form", :media, [
      %{name: "foto.jpg", content: File.read!(jpg), type: "image/jpeg"}
    ])
    |> render_upload("foto.jpg")

    refute render(lv) =~ ~s(data-role="preview-button")
  end
end
