defmodule Camerex.Parser.HairTest do
  use ExUnit.Case, async: true

  alias Camerex.Parser.Hair

  @hair_rgb {90, 60, 50}

  # Cena 240×240: pessoa (retângulo) com um CACHO de @hair_rgb (marrom) no topo e
  # pele clara no resto. `labels` = roupa (classe 4) na pessoa, SEM cabelo (classe
  # 2 = 0) — simula o caso aéreo em que o ATR cega para a cabeça.
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

    person = rect.({40, 200, 60, 180})
    hair = rect.(Keyword.get(opts, :hair_rect, {52, 96, 92, 148}))

    person3 = Nx.broadcast(Nx.new_axis(person, -1), {w, w, 3})
    hair3 = Nx.broadcast(Nx.new_axis(hair, -1), {w, w, 3})
    brown = Nx.tensor(Tuple.to_list(@hair_rgb), type: :u8) |> Nx.broadcast({w, w, 3})
    skin = Nx.tensor([200, 150, 140], type: :u8) |> Nx.broadcast({w, w, 3})
    black = Nx.broadcast(Nx.u8(0), {w, w, 3})

    rgb = person3 |> Nx.select(skin, black) |> then(&Nx.select(hair3, brown, &1))
    fg = person |> Nx.multiply(255) |> Nx.as_type(:u8)
    labels = Nx.select(person, Nx.u8(4), Nx.u8(0))

    {fg, labels, rgb}
  end

  test "acha o cacho pela cor dentro da silhueta (u8 {h,w})" do
    {fg, labels, rgb} = scene()
    mask = Hair.detect(fg, labels, rgb, @hair_rgb)

    assert Nx.shape(mask) == {240, 240}
    assert Nx.type(mask) == {:u, 8}
    # centro do cacho aceso; um ponto de pele/fundo, não
    assert Nx.to_number(mask[74][120]) == 255
    assert Nx.to_number(mask[150][120]) == 0
  end

  test "sem cor indicada: o fallback não dispara (máscara vazia)" do
    {fg, labels, rgb} = scene()
    assert Nx.to_number(Nx.sum(Hair.detect(fg, labels, rgb, nil))) == 0
  end

  test "sem rgb: não há como medir cor (máscara vazia)" do
    {fg, labels, _rgb} = scene()
    assert Nx.to_number(Nx.sum(Hair.detect(fg, labels, nil, @hair_rgb))) == 0
  end

  test "cor ausente da cena (verde) não acende nada (precisão)" do
    {fg, labels, rgb} = scene()
    assert Nx.to_number(Nx.sum(Hair.detect(fg, labels, rgb, {0, 255, 0}))) == 0
  end

  test "sensibilidade alta pega pelo menos tanto quanto a baixa" do
    {fg, labels, rgb} = scene()
    baixa = Hair.detect(fg, labels, rgb, @hair_rgb, sensitivity: 0.1)
    alta = Hair.detect(fg, labels, rgb, @hair_rgb, sensitivity: 0.9)
    n = fn m -> Nx.to_number(Nx.sum(Nx.greater(m, 0))) end
    assert n.(alta) >= n.(baixa)
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
    # bloco minúsculo de cabelo (100px < 0.3% de 57600) ainda conta como ausente
    tiny =
      Nx.put_slice(Nx.broadcast(Nx.u8(0), {240, 240}), [0, 0], Nx.broadcast(Nx.u8(2), {10, 10}))

    refute Hair.present?(tiny)
  end
end
