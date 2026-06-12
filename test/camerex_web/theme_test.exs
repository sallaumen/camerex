defmodule CamerexWeb.ThemeTest do
  use CamerexWeb.ConnCase, async: false

  test "root layout aplica o tema dark", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ ~s(<body class="bg-cx-bg text-cx-text antialiased")
  end
end
