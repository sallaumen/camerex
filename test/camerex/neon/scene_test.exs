defmodule Camerex.Neon.SceneTest do
  use ExUnit.Case, async: true

  alias Camerex.Neon.Scene

  # neon sintético: um bloco aceso (ciano) sobre fundo preto 80×60, com folga
  # abaixo dos "pés" para a metade de baixo da poça caber
  defp neon_scene do
    rows = Nx.iota({80, 60}, axis: 0)
    cols = Nx.iota({80, 60}, axis: 1)

    block =
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, 10), Nx.less(rows, 60)),
        Nx.logical_and(Nx.greater_equal(cols, 20), Nx.less(cols, 40))
      )

    on = Nx.tensor([0, 200, 255], type: :u8)

    Nx.select(
      Nx.new_axis(block, -1) |> Nx.broadcast({80, 60, 3}),
      on,
      Nx.broadcast(Nx.u8(0), {80, 60, 3})
    )
  end

  defp total(t), do: t |> Nx.sum() |> Nx.to_number()

  test "apply/2 estende a altura (metade de baixo da poça)" do
    neon = neon_scene()
    {h, w, _} = Nx.shape(neon)

    {oh, ow, oc} = Scene.apply(neon) |> Nx.shape()

    assert ow == w
    assert oc == 3
    assert oh > h
  end

  test "glow ilumina ao redor dos pés (mais claro que sem glow)" do
    neon = neon_scene()

    com = Scene.apply(neon, glow: 0.9) |> total()
    sem = Scene.apply(neon, glow: 0.0) |> total()

    assert com > sem
  end

  test "glow: 0 não adiciona luz — região original intacta e piso preto" do
    neon = neon_scene()
    {h, _, _} = Nx.shape(neon)

    out = Scene.apply(neon, glow: 0.0)
    {oh, _, _} = Nx.shape(out)

    # a parte de cima é o neon original byte a byte; o piso anexado fica preto
    assert Nx.to_binary(Nx.slice_along_axis(out, 0, h, axis: 0)) == Nx.to_binary(neon)
    assert Nx.slice_along_axis(out, h, oh - h, axis: 0) |> total() == 0
  end

  test "espalhamento maior aumenta a poça (mais luz no total)" do
    neon = neon_scene()

    estreito = Scene.apply(neon, glow: 0.9, spread: 0.1) |> total()
    largo = Scene.apply(neon, glow: 0.9, spread: 1.0) |> total()

    assert largo > estreito
  end

  test "sem nada aceso devolve o neon intacto (sem chão)" do
    black = Nx.broadcast(Nx.u8(0), {30, 20, 3})

    assert Scene.apply(black) == black
  end
end
