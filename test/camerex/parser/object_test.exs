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

  describe "instrumento incompleto (componente pequeno)" do
    # cena 200×200 (área 40000): pessoa à esquerda + um objeto PEQUENO (~250px =
    # 0.6%, abaixo do limiar grande de 1%) cuja posição varia. min=1%→400px;
    # borda=0.2%→80px.
    defp scene_small_object(:edge) do
      # faixa fina colada na borda de baixo (instrumento CORTADO pelo quadro)
      build(person_rect(), {195, 200, 90, 140})
    end

    defp scene_small_object(:interior) do
      # mesmo tamanho, mas solto no meio (chuvisco — não toca borda)
      build(person_rect(), {95, 100, 130, 180})
    end

    defp person_rect, do: {40, 120, 30, 90}

    defp build({pr0, pr1, pc0, pc1}, {or0, or1, oc0, oc1}) do
      rows = Nx.iota({200, 200}, axis: 0)
      cols = Nx.iota({200, 200}, axis: 1)

      rect = fn r0, r1, c0, c1 ->
        Nx.logical_and(
          Nx.logical_and(Nx.greater_equal(rows, r0), Nx.less(rows, r1)),
          Nx.logical_and(Nx.greater_equal(cols, c0), Nx.less(cols, c1))
        )
      end

      person = rect.(pr0, pr1, pc0, pc1)
      object = rect.(or0, or1, oc0, oc1)
      labels = Nx.select(person, Nx.u8(4), Nx.u8(0))
      fg = Nx.logical_or(person, object) |> Nx.multiply(255) |> Nx.as_type(:u8)
      {fg, labels}
    end

    test "objeto pequeno que TOCA a borda do quadro é mantido (instrumento cortado)" do
      {fg, labels} = scene_small_object(:edge)
      mask = Object.detect(fg, labels)
      assert Nx.to_number(Nx.sum(Nx.greater(mask, 0))) > 0
    end

    test "objeto pequeno SOLTO no meio (não toca borda) é descartado como ruído" do
      {fg, labels} = scene_small_object(:interior)
      mask = Object.detect(fg, labels)
      assert Nx.to_number(Nx.sum(Nx.greater(mask, 0))) == 0
    end
  end
end
