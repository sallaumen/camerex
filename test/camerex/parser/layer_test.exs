defmodule Camerex.Parser.LayerTest do
  use ExUnit.Case, async: true
  alias Camerex.Parser.{Apparatus, Hair, LayerContext, Object, Skin}

  setup do
    rgb = Nx.broadcast(Nx.u8(120), {32, 32, 3})
    labels = Nx.broadcast(Nx.u8(0), {32, 32})
    fg = Nx.broadcast(Nx.u8(255), {32, 32})
    {:ok, rgb: rgb, labels: labels, fg: fg}
  end

  test "Object.run/1 aceita LayerContext e devolve máscara u8 {h,w}", ctx do
    out = Object.run(%LayerContext{rgb: ctx.rgb, labels: ctx.labels, fg: ctx.fg})
    assert Nx.shape(out) == {32, 32}
  end

  test "Skin.run/1 não exige ctx.fg nem ctx.color (auto)", ctx do
    out = Skin.run(%LayerContext{rgb: ctx.rgb, labels: ctx.labels, fg: nil, color: nil})
    assert Nx.shape(out) == {32, 32}
  end

  test "Hair.run/1 com color=nil devolve máscara vazia (required)", ctx do
    out =
      Hair.run(%LayerContext{
        rgb: ctx.rgb,
        labels: ctx.labels,
        fg: ctx.fg,
        color: nil,
        sensitivity: 0.5
      })

    assert Nx.to_number(Nx.sum(out)) == 0
  end

  test "Apparatus.run/1 com color=nil ainda roda (optional)", ctx do
    out =
      Apparatus.run(%LayerContext{
        rgb: ctx.rgb,
        labels: ctx.labels,
        fg: ctx.fg,
        color: nil,
        sensitivity: 0.5
      })

    assert Nx.shape(out) == {32, 32}
  end

  test "Hair implementa Layer.Sampleable.sample_region/2" do
    Code.ensure_loaded(Hair)
    assert function_exported?(Hair, :sample_region, 2)
  end
end
