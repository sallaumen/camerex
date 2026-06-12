defmodule Camerex.WorkspaceCase do
  @moduledoc """
  Case template para testes que tocam o workspace em disco: aponta
  :workspace_root para o tmp_dir do teste e restaura no on_exit.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      @moduletag :tmp_dir
    end
  end

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:camerex, :workspace_root)
    Application.put_env(:camerex, :workspace_root, tmp_dir)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:camerex, :workspace_root)
        val -> Application.put_env(:camerex, :workspace_root, val)
      end
    end)

    {:ok, workspace_root: tmp_dir}
  end
end
