defmodule Camerex.SystemStatsTest do
  use ExUnit.Case, async: true

  alias Camerex.SystemStats

  test "snapshot/0 traz CPU, RAM, BEAM e schedulers com tipos sãos" do
    s = SystemStats.snapshot()

    assert is_integer(s.beam_mb) and s.beam_mb > 0
    assert is_integer(s.schedulers) and s.schedulers > 0

    # CPU: % inteiro em 0..100, ou nil se a porta do os_mon hesitou
    assert s.cpu_pct == nil or (is_integer(s.cpu_pct) and s.cpu_pct in 0..100)

    # RAM: nil, ou mapa coerente (usado <= total, pct em 0..100)
    case s.mem do
      nil ->
        :ok

      %{used_mb: used, total_mb: total, pct: pct} ->
        assert is_integer(used) and is_integer(total) and total > 0
        assert used <= total
        assert pct in 0..100
    end
  end
end
