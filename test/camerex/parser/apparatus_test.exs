defmodule Camerex.Parser.ApparatusTest do
  use ExUnit.Case, async: true

  alias Camerex.Parser.Apparatus

  @red {220, 30, 40}

  # Cena 240×240: rgb com `silk_rects` em VERMELHO saturado sobre cinza (sat~0);
  # fg = onde há vermelho; labels = `person_rect` como classe 4 (ou 2 = cabelo).
  defp build(silk_rects, opts \\ []) do
    w = 240
    rows = Nx.iota({w, w}, axis: 0)
    cols = Nx.iota({w, w}, axis: 1)

    rect = fn {r0, r1, c0, c1} ->
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, r0), Nx.less(rows, r1)),
        Nx.logical_and(Nx.greater_equal(cols, c0), Nx.less(cols, c1))
      )
    end

    empty = Nx.broadcast(Nx.u8(0), {w, w}) |> Nx.greater(1)
    silk = Enum.reduce(silk_rects, empty, fn r, acc -> Nx.logical_or(acc, rect.(r)) end)

    red = Nx.tensor([220, 30, 40], type: :u8) |> Nx.broadcast({w, w, 3})
    gray = Nx.broadcast(Nx.u8(128), {w, w, 3})
    rgb = Nx.select(Nx.broadcast(Nx.new_axis(silk, -1), {w, w, 3}), red, gray)
    fg = silk |> Nx.multiply(255) |> Nx.as_type(:u8)

    labels =
      case {Keyword.get(opts, :person), Keyword.get(opts, :hair)} do
        {nil, nil} -> Nx.broadcast(Nx.u8(0), {w, w})
        {p, nil} -> Nx.select(rect.(p), Nx.u8(4), Nx.u8(0))
        {nil, hr} -> Nx.select(rect.(hr), Nx.u8(2), Nx.u8(0))
      end

    {fg, labels, rgb}
  end

  test "fita vertical fina que ALCANÇA O TOPO vira tecido" do
    # faixa de 14px de largura, do topo até a metade de baixo
    {fg, labels, rgb} = build([{0, 200, 110, 124}])

    mask = Apparatus.detect(fg, labels, rgb, @red)

    assert Nx.shape(mask) == {240, 240}
    assert Nx.type(mask) == {:u, 8}
    # corpo da fita aceso
    assert Nx.to_number(mask[100][117]) == 255
  end

  test "blob compacto e GROSSO não vira tecido (proteção contra manchas)" do
    # 70×70 de área cheia, alcança o topo — mas é grosso (não é uma fita)
    {fg, labels, rgb} = build([{0, 70, 90, 160}])

    mask = Apparatus.detect(fg, labels, rgb, @red)
    assert Nx.to_number(Nx.sum(Nx.greater(mask, 0))) == 0
  end

  test "fita que NÃO alcança o topo é descartada (invariante: tecido vem de cima)" do
    # faixa fina mas só na metade de BAIXO (rows 130..240) — "só embaixo" não existe
    {fg, labels, rgb} = build([{130, 240, 110, 124}])

    mask = Apparatus.detect(fg, labels, rgb, @red)
    assert Nx.to_number(Nx.sum(Nx.greater(mask, 0))) == 0
  end

  test "fita que CURVA mas continua FINA é mantida inteira (segue ao longo de si)" do
    # vertical do topo (rows 0..140) + continuação inclinada FINA embaixo (16px) —
    # como o tecido que curva ao passar pelas pernas; fica tudo conectado
    {fg, labels, rgb} = build([{0, 140, 110, 126}, {130, 205, 124, 140}])

    mask = Apparatus.detect(fg, labels, rgb, @red)
    assert Nx.to_number(mask[60][117]) == 255
    # a continuação de baixo também acende (cresceu pela fita)
    assert Nx.to_number(Nx.sum(Nx.greater(mask[[150..200, 124..140]], 0))) > 0
  end

  test "cabelo (classe 2) da cor do tecido não é roubado (regressão: cabelo rosa)" do
    # fita de silk à direita (alcança topo) + blob de cabelo vermelho (classe 2) à
    # esquerda, longe dela. O cabelo e sua vizinhança não podem virar tecido.
    {fg, labels, rgb} = build([{0, 200, 150, 164}], hair: {20, 60, 40, 75})

    mask = Apparatus.detect(fg, labels, rgb, @red)
    # a fita continua sendo tecido
    assert Nx.to_number(mask[100][157]) == 255
    # o cabelo NÃO
    assert Nx.to_number(mask[40][57]) == 0
  end

  test "into_labels/2 injeta a classe 19 só onde há tecido E o ATR não rotulou" do
    {fg, labels, rgb} = build([{0, 200, 110, 124}])
    mask = Apparatus.detect(fg, labels, rgb, @red)

    augmented = Apparatus.into_labels(labels, mask)
    assert Nx.to_number(augmented[100][117]) == 19
    # fora do tecido segue fundo
    assert Nx.to_number(augmented[100][10]) == 0
  end

  test "sem rgb/cor: cai na saliência pura (fita do fg vira tecido)" do
    {fg, labels, _rgb} = build([{0, 200, 110, 124}])

    mask = Apparatus.detect(fg, labels)
    assert Nx.to_number(mask[100][117]) == 255
  end
end
