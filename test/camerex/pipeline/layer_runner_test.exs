defmodule Camerex.Pipeline.LayerRunnerTest do
  use ExUnit.Case, async: true
  alias Camerex.Pipeline.LayerRunner

  setup do
    rgb = Nx.broadcast(Nx.u8(120), {32, 32, 3})
    labels = Nx.broadcast(Nx.u8(0), {32, 32})
    fg_largest = Nx.broadcast(Nx.u8(255), {32, 32})
    fg_full = Nx.broadcast(Nx.u8(255), {32, 32})

    fg_provider = fn
      {"u2net", :largest} -> fg_largest
      {"u2netp", :full} -> fg_full
      _ -> nil
    end

    {:ok, rgb: rgb, labels: labels, fg_provider: fg_provider}
  end

  test "nenhuma camada ativa → labels não mudam", %{rgb: rgb, labels: labels, fg_provider: fp} do
    assert LayerRunner.run(labels, rgb, %{}, fg_provider: fp) == labels
  end

  test "ordena por order_band: baseline → overlay → destructive (não crasha com múltiplas)", %{
    rgb: rgb,
    labels: labels,
    fg_provider: fp
  } do
    params = %{"detect_object" => true, "detect_skin" => true}
    out = LayerRunner.run(labels, rgb, params, fg_provider: fp)
    assert Nx.shape(out) == Nx.shape(labels)
  end

  test "hair ligado SEM cor (required) → no-op (NÃO chama fg_provider)", %{
    rgb: rgb,
    labels: labels
  } do
    # fg_provider que crasha se chamado prova que Hair foi pulado antes do detect
    fp = fn _ -> raise "não deveria pedir fg pra Hair sem cor" end
    params = %{"detect_hair" => true}
    out = LayerRunner.run(labels, rgb, params, fg_provider: fp)
    assert out == labels
  end

  test "skin (fg_spec :none) não consulta fg_provider", %{rgb: rgb, labels: labels} do
    fp = fn _ -> raise "Skin não deveria pedir fg" end
    params = %{"detect_skin" => true}
    out = LayerRunner.run(labels, rgb, params, fg_provider: fp)
    # labels todo zero + sem pele-ATR (trava @min_skin_frac do Skin) → labels intacto
    assert Nx.to_number(Nx.sum(out)) == 0
  end
end
