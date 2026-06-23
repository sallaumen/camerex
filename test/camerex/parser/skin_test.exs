defmodule Camerex.Parser.SkinTest do
  use ExUnit.Case, async: true

  alias Camerex.Parser.Skin

  @skin {200, 150, 130}
  @dark {50, 40, 40}

  # Cena 240×240: BRAÇO (pele, classe 14) + TORÇO nu mal-rotulado como vestido
  # (classe 7, MESMA cor de pele, contíguo ao braço) + CALÇA escura (classe 6,
  # mais escura). Skin deve re-rotular o torço (pele), não a calça.
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

    empty = rect.({0, 0, 0, 0})
    arm = if Keyword.get(opts, :no_limb, false), do: empty, else: rect.({60, 100, 40, 200})
    torso = rect.({100, 160, 80, 160})
    pants = rect.({160, 210, 80, 160})

    skin3 = Nx.tensor(Tuple.to_list(@skin), type: :u8) |> Nx.broadcast({w, w, 3})
    dark3 = Nx.tensor(Tuple.to_list(@dark), type: :u8) |> Nx.broadcast({w, w, 3})
    skinmask = Nx.logical_or(arm, torso) |> Nx.new_axis(-1) |> Nx.broadcast({w, w, 3})
    pants3 = pants |> Nx.new_axis(-1) |> Nx.broadcast({w, w, 3})

    rgb =
      Nx.broadcast(Nx.u8(0), {w, w, 3})
      |> then(&Nx.select(skinmask, skin3, &1))
      |> then(&Nx.select(pants3, dark3, &1))

    labels =
      Nx.broadcast(Nx.u8(0), {w, w})
      |> then(&Nx.select(arm, Nx.u8(14), &1))
      |> then(&Nx.select(torso, Nx.u8(7), &1))
      |> then(&Nx.select(pants, Nx.u8(6), &1))

    {labels, rgb}
  end

  test "re-rotula o torço nu (vestido, cor de pele, contíguo aos membros) como pele" do
    {labels, rgb} = scene()
    out = Skin.into_labels(labels, Skin.detect(labels, rgb))
    # centro do torço (era 7 = vestido) vira pele (11)
    assert Nx.to_number(out[130][120]) == 11
  end

  test "a CALÇA escura (mais escura que a pele) NÃO vira pele" do
    {labels, rgb} = scene()
    out = Skin.into_labels(labels, Skin.detect(labels, rgb))
    # centro da calça (6) continua roupa
    assert Nx.to_number(out[185][120]) == 6
  end

  test "into_labels só re-rotula ROUPA — membros (braço, 14) ficam intactos" do
    {labels, rgb} = scene()
    out = Skin.into_labels(labels, Skin.detect(labels, rgb))
    assert Nx.to_number(out[80][120]) == 14
  end

  test "sem pele-ATR (membros cobertos): não adivinha (máscara vazia)" do
    {labels, rgb} = scene(no_limb: true)
    assert Nx.to_number(Nx.sum(Skin.detect(labels, rgb))) == 0
  end
end
