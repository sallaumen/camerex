defmodule Camerex.Parser.HairTest do
  use ExUnit.Case, async: true

  alias Camerex.Parser.Hair

  @base {120, 80, 60}

  # Cena 240×240: um CACHO texturizado (listras de luminância) + uma região de
  # pele LISA da MESMA cor + fundo preto. labels = roupa (classe 4) na pessoa,
  # SEM cabelo (classe 2 = 0) — simula o caso aéreo em que o ATR cega. A textura
  # é o que deve separar o cacho da pele da mesma cor.
  defp scene(opts \\ []) do
    w = 240
    rows = Nx.iota({w, w}, axis: 0)
    cols = Nx.iota({w, w}, axis: 1)

    rect = fn {r0, r1, c0, c1} ->
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, r0), Nx.less(rows, r1)),
        Nx.logical_and(Nx.greater_equal(cols, c0), Nx.less(cols, c1))
      )
    end

    person = rect.({30, 210, 40, 200})
    hair = rect.(Keyword.get(opts, :hair_rect, {54, 120, 88, 152}))
    skin = rect.(Keyword.get(opts, :skin_rect, {130, 190, 88, 152}))

    {br, bg, bb} = @base
    base = Nx.tensor([br, bg, bb], type: :f32) |> Nx.broadcast({w, w, 3})
    # listras de ±18 na luminância a cada linha → textura local alta, cor ~base
    stripe = rows |> Nx.remainder(2) |> Nx.multiply(36) |> Nx.subtract(18) |> Nx.as_type(:f32)
    textured = Nx.add(base, stripe |> Nx.new_axis(-1) |> Nx.broadcast({w, w, 3}))

    hair3 = Nx.broadcast(Nx.new_axis(hair, -1), {w, w, 3})
    skin3 = Nx.broadcast(Nx.new_axis(skin, -1), {w, w, 3})

    rgb =
      Nx.broadcast(Nx.tensor(0.0), {w, w, 3})
      |> then(&Nx.select(skin3, base, &1))
      |> then(&Nx.select(hair3, textured, &1))
      |> Nx.clip(0, 255)
      |> Nx.as_type(:u8)

    fg = person |> Nx.multiply(255) |> Nx.as_type(:u8)
    labels = Nx.select(person, Nx.u8(4), Nx.u8(0))

    {fg, labels, rgb}
  end

  test "acha o cacho texturizado pela cor (u8 {h,w})" do
    {fg, labels, rgb} = scene()
    mask = Hair.detect(fg, labels, rgb, @base, sensitivity: 0.6)

    assert Nx.shape(mask) == {240, 240}
    assert Nx.type(mask) == {:u, 8}
    # centro do cacho aceso
    assert Nx.to_number(mask[85][120]) == 255
  end

  test "a TEXTURA separa: a pele LISA da mesma cor NÃO vira cabelo" do
    {fg, labels, rgb} = scene()
    mask = Hair.detect(fg, labels, rgb, @base, sensitivity: 0.6)

    # cacho (texturizado) aceso; pele (lisa, MESMA cor) apagada
    assert Nx.to_number(mask[85][120]) == 255
    assert Nx.to_number(mask[160][120]) == 0
  end

  test "uma FITA vertical longa (tecido aéreo) é descartada — cabelo é cacho" do
    # fita texturizada alta-e-fina da cor do cabelo (aspect ≫ 3.5), sem pele
    {fg, labels, rgb} = scene(hair_rect: {30, 205, 110, 124}, skin_rect: {0, 0, 0, 0})
    mask = Hair.detect(fg, labels, rgb, @base, sensitivity: 0.6)

    assert Nx.to_number(Nx.sum(Nx.greater(mask, 0))) == 0
  end

  test "sem cor indicada ou sem rgb: o fallback não dispara (vazio)" do
    {fg, labels, rgb} = scene()
    assert Nx.to_number(Nx.sum(Hair.detect(fg, labels, rgb, nil))) == 0
    assert Nx.to_number(Nx.sum(Hair.detect(fg, labels, nil, @base))) == 0
  end

  test "cor ausente da cena (verde) não acende nada (precisão)" do
    {fg, labels, rgb} = scene()
    assert Nx.to_number(Nx.sum(Hair.detect(fg, labels, rgb, {0, 255, 0}, sensitivity: 0.6))) == 0
  end

  test "sensibilidade alta pega ao menos tanto quanto a baixa" do
    {fg, labels, rgb} = scene()
    n = fn m -> Nx.to_number(Nx.sum(Nx.greater(m, 0))) end

    assert n.(Hair.detect(fg, labels, rgb, @base, sensitivity: 0.9)) >=
             n.(Hair.detect(fg, labels, rgb, @base, sensitivity: 0.5))
  end

  test "into_labels/2 vira 2 sobre fundo/roupa, preserva membro e rosto" do
    mask = Nx.broadcast(Nx.u8(255), {2, 4})
    # colunas: fundo(0), roupa(4) → viram 2; braço(14), rosto(11) → preservados
    labels = Nx.tensor([[0, 4, 14, 11], [0, 4, 14, 11]], type: :u8)

    out = Hair.into_labels(labels, mask)
    assert Nx.to_flat_list(out) == [2, 2, 14, 11, 2, 2, 14, 11]
  end

  test "present?/1: true quando a classe 2 é abundante, false quando ~0" do
    refute Hair.present?(Nx.broadcast(Nx.u8(0), {240, 240}))
    assert Hair.present?(Nx.broadcast(Nx.u8(2), {240, 240}))
    # bloco minúsculo (100px < 0.3% de 57600) ainda conta como ausente
    tiny =
      Nx.put_slice(Nx.broadcast(Nx.u8(0), {240, 240}), [0, 0], Nx.broadcast(Nx.u8(2), {10, 10}))

    refute Hair.present?(tiny)
  end
end
