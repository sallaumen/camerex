defmodule Camerex.Neon.SceneTest do
  use ExUnit.Case, async: true

  alias Camerex.Neon.Scene

  # neon sintético: um bloco aceso (ciano) no topo de um fundo preto 80×60
  defp neon_scene do
    rows = Nx.iota({80, 60}, axis: 0)
    cols = Nx.iota({80, 60}, axis: 1)

    # bloco alto, indo quase até a base (pés perto do fim → piso anexado embaixo)
    block =
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, 10), Nx.less(rows, 76)),
        Nx.logical_and(Nx.greater_equal(cols, 20), Nx.less(cols, 40))
      )

    on = Nx.tensor([0, 200, 255], type: :u8)

    Nx.select(
      Nx.new_axis(block, -1) |> Nx.broadcast({80, 60, 3}),
      on,
      Nx.broadcast(Nx.u8(0), {80, 60, 3})
    )
  end

  test "apply/2 anexa o piso: imagem fica mais alta que a original" do
    neon = neon_scene()
    {h, w, _} = Nx.shape(neon)

    out = Scene.apply(neon)
    {oh, ow, oc} = Nx.shape(out)

    assert ow == w
    assert oc == 3
    assert oh > h
  end

  test "o reflexo enche o piso com conteúdo (não fica preto)" do
    neon = neon_scene()
    {h, _, _} = Nx.shape(neon)
    out = Scene.apply(neon, reflection: 0.8, pool: 0.7)

    {oh, _, _} = Nx.shape(out)
    floor = Nx.slice_along_axis(out, h, oh - h, axis: 0)

    assert floor |> Nx.sum() |> Nx.to_number() > 0
  end

  test "reflexo/poça em 0 deixa o piso praticamente escuro" do
    neon = neon_scene()
    {h, _, _} = Nx.shape(neon)
    out = Scene.apply(neon, reflection: 0.0, pool: 0.0, ripple: 0.0)

    {oh, _, _} = Nx.shape(out)
    floor = Nx.slice_along_axis(out, h, oh - h, axis: 0)

    assert floor |> Nx.sum() |> Nx.to_number() == 0
  end
end
