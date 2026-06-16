defmodule CamerexWeb.ExportController do
  @moduledoc """
  Download em massa: empacota os resultados prontos de uma pasta num `.zip`.
  `GET /export/folder?folder=<nome>` (folder vazio = raiz da biblioteca).
  """
  use CamerexWeb, :controller

  alias Camerex.Library.Export

  def folder(conn, params) do
    case Export.zip(Map.get(params, "folder", "")) do
      {:ok, %{filename: filename, data: data}} ->
        conn
        |> put_resp_content_type("application/zip")
        |> send_download({:binary, data}, filename: filename)

      {:error, :empty} ->
        conn
        |> put_status(:not_found)
        |> text("nenhum resultado pronto nesta pasta")
    end
  end
end
