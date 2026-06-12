defmodule CamerexWeb.RedirectController do
  use CamerexWeb, :controller

  @doc "Deep-link da v1 (`/item/:id`) → biblioteca single-page (`/?item=`)."
  def legacy_item(conn, %{"id" => id}) do
    redirect(conn, to: ~p"/?#{[item: id]}")
  end
end
