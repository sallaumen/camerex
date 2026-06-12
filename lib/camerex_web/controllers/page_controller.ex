defmodule CamerexWeb.PageController do
  use CamerexWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
