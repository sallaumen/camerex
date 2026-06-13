defmodule Camerex.WorkspaceCase do
  @moduledoc """
  Case template para testes que tocam o workspace: aponta o
  workspace_root para o tmp_dir do teste (restaurando no on_exit)
  e oferece helpers de seed de itens.

  Testes web (que precisam do ConnCase) não podem usar dois case
  templates: nesses, faça `import Camerex.WorkspaceCase` +
  `@moduletag :tmp_dir` + `setup :override_workspace_root`.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      @moduletag :tmp_dir
      import Camerex.WorkspaceCase

      setup :override_workspace_root
    end
  end

  @doc "Setup: workspace_root → tmp_dir do teste, restaurado no on_exit."
  def override_workspace_root(%{tmp_dir: tmp}) do
    prev = Application.fetch_env!(:camerex, :workspace_root)
    Application.put_env(:camerex, :workspace_root, tmp)
    on_exit(fn -> Application.put_env(:camerex, :workspace_root, prev) end)
    %{tmp: tmp, workspace_root: tmp}
  end

  @doc "Params default de conversão (mesmos defaults da UI)."
  def default_params do
    %{
      "halo" => 0.6,
      "trail" => 0.7,
      "detail" => 0.5,
      "swap_sides" => false,
      "model" => "u2net"
    }
  end

  @doc """
  Grava um PNG cinza 48×32 e cria um item de foto a partir dele.
  attrs[:status] força o status do manifest após a criação.
  """
  def create_photo_item!(tmp, attrs \\ %{}) do
    src = Path.join(tmp, "fonte-#{System.unique_integer([:positive])}.png")
    rgb = Nx.broadcast(Nx.u8(120), {32, 48, 3})
    true = Evision.imwrite(src, Evision.Mat.from_nx_2d(rgb))

    {:ok, id} =
      Camerex.Workspace.create_item(src, "fonte.png", :photo, "forro-teal", default_params())

    case attrs[:status] do
      nil ->
        id

      status ->
        {:ok, _} =
          Camerex.Workspace.update_manifest(id, fn manifest ->
            manifest
            |> Map.put("status", status)
            |> complete_if_done(status)
          end)

        id
    end
  end

  # itens done reais sempre têm completed_at (o ?v= das URLs deriva dele)
  defp complete_if_done(manifest, "done"),
    do: Map.put(manifest, "completed_at", DateTime.to_iso8601(DateTime.utc_now()))

  defp complete_if_done(manifest, _status), do: manifest
end
