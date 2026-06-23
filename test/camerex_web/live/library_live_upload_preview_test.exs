defmodule CamerexWeb.LibraryLiveUploadPreviewTest do
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

  defp poll_calib_img(lv) do
    Enum.find_value(1..100, fn _ ->
      Process.sleep(10)

      case lv
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("[data-role=calib-img]")
           |> LazyHTML.attribute("src") do
        [src] -> src
        _ -> nil
      end
    end)
  end

  test "upload de foto abre a prévia ao vivo automaticamente", %{conn: conn, jpg: jpg} do
    {:ok, lv, _html} = live(conn, "/")
    lv |> element("#new-conversion") |> render_click()

    lv
    |> file_input("#convert-form", :media, [
      %{name: "foto.jpg", content: File.read!(jpg), type: "image/jpeg"}
    ])
    |> render_upload("foto.jpg")

    assert render(lv) =~ "calib-preview"
    assert poll_calib_img(lv) =~ "data:image/png;base64,"
  end

  test "upload de vídeo abre a prévia ao vivo do frame central", %{conn: conn, mp4: mp4} do
    {:ok, lv, _html} = live(conn, "/")
    lv |> element("#new-conversion") |> render_click()

    lv
    |> file_input("#convert-form", :media, [
      %{name: "clip.mp4", content: File.read!(mp4), type: "video/mp4"}
    ])
    |> render_upload("clip.mp4")

    assert poll_calib_img(lv) =~ "data:image/png;base64,"
    # o fluxo manual de prévia morreu junto do botão
    refute render(lv) =~ ~s(data-role="preview-button")
  end

  test "Converter consome o upload e desliga a prévia", %{conn: conn, jpg: jpg} do
    {:ok, lv, _html} = live(conn, "/")
    lv |> element("#new-conversion") |> render_click()

    lv
    |> file_input("#convert-form", :media, [
      %{name: "foto.jpg", content: File.read!(jpg), type: "image/jpeg"}
    ])
    |> render_upload("foto.jpg")

    assert poll_calib_img(lv)

    lv |> form("#convert-form", %{}) |> render_submit()

    refute render(lv) =~ "calib-preview"
    assert [%{"original_filename" => "foto.jpg"}] = Camerex.Workspace.list_items()
  end

  test "conta-gotas do cabelo: arma na prévia e captura a cor", %{conn: conn, jpg: jpg} do
    {:ok, lv, _html} = live(conn, "/")
    lv |> element("#new-conversion") |> render_click()

    lv
    |> file_input("#convert-form", :media, [
      %{name: "foto.jpg", content: File.read!(jpg), type: "image/jpeg"}
    ])
    |> render_upload("foto.jpg")

    assert poll_calib_img(lv)

    # liga o resgate de cabelo pro sub-bloco + botão do conta-gotas aparecerem
    lv |> form("#convert-form", %{"detect_hair" => "true"}) |> render_change()

    html = render(lv)
    assert html =~ "pegar cor do cabelo na foto"
    assert html =~ ~s(phx-hook="EyedropHair")
    refute html =~ "cursor-crosshair"

    # arma: a img da prévia vira alvo (cursor-crosshair + data-armed)
    armed = lv |> element("button", "pegar cor do cabelo na foto") |> render_click()
    assert armed =~ ~s(data-armed="true")
    assert armed =~ "cursor-crosshair"

    # clique armado no centro: o handler amostra a cor e produz um flash
    captured =
      lv |> element("#calib-img") |> render_hook("eyedrop_hair", %{"xf" => 0.5, "yf" => 0.5})

    assert captured =~ "cor do cabelo capturada" or captured =~ "clique no cabelo"
  end
end
