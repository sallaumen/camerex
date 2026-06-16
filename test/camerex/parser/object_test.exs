defmodule Camerex.Parser.ObjectTest do
  use ExUnit.Case, async: true

  alias Camerex.Parser.Object

  # cena sintética: PESSOA (rótulo 4) num bloco à esquerda e um OBJETO isolado
  # (foreground sem rótulo) à direita, separados por um vão > a dilatação.
  defp scene do
    h = 200
    w = 200
    rows = Nx.iota({h, w}, axis: 0)
    cols = Nx.iota({h, w}, axis: 1)

    rect = fn r0, r1, c0, c1 ->
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, r0), Nx.less(rows, r1)),
        Nx.logical_and(Nx.greater_equal(cols, c0), Nx.less(cols, c1))
      )
    end

    person = rect.(40, 160, 20, 80)
    object = rect.(60, 140, 130, 180)

    labels = Nx.select(person, Nx.u8(4), Nx.u8(0))
    fg = Nx.logical_or(person, object) |> Nx.multiply(255) |> Nx.as_type(:u8)
    {fg, labels}
  end

  test "detect/2 isola o objeto na mão (foreground − pessoa), descartando a pessoa" do
    {fg, labels} = scene()

    mask = Object.detect(fg, labels)

    assert Nx.shape(mask) == {200, 200}
    # centro do objeto vira máscara…
    assert Nx.to_number(mask[100][155]) == 255
    # …e o centro da pessoa NÃO (foi subtraída antes)
    assert Nx.to_number(mask[100][50]) == 0
  end

  test "detect/2 sem objeto (foreground ≈ pessoa) devolve máscara vazia" do
    {_fg, labels} = scene()
    # foreground = só a pessoa → nada a detectar
    person_only = labels |> Nx.greater(0) |> Nx.multiply(255) |> Nx.as_type(:u8)

    mask = Object.detect(person_only, labels)

    assert Nx.to_number(Nx.sum(mask)) == 0
  end

  test "into_labels/2 injeta a classe 18 só onde há objeto E o ATR não rotulou nada" do
    {fg, labels} = scene()
    mask = Object.detect(fg, labels)

    augmented = Object.into_labels(labels, mask)

    # objeto vira classe 18…
    assert Nx.to_number(augmented[100][155]) == 18
    # …e a pessoa (classe 4) fica intacta
    assert Nx.to_number(augmented[100][50]) == 4
  end
end
