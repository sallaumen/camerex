defmodule Camerex.Parser.ApparatusTest do
  use ExUnit.Case, async: true

  alias Camerex.Parser.Apparatus

  # cena 200×200: PESSOA (rótulo 4) num bloco + uma estrutura conforme o caso.
  # min altura = 35%→70px; min área = 0.5%→200px.
  defp scene(extra_rect) do
    rows = Nx.iota({200, 200}, axis: 0)
    cols = Nx.iota({200, 200}, axis: 1)

    rect = fn {r0, r1, c0, c1} ->
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, r0), Nx.less(rows, r1)),
        Nx.logical_and(Nx.greater_equal(cols, c0), Nx.less(cols, c1))
      )
    end

    person = rect.({80, 140, 40, 90})
    extra = rect.(extra_rect)
    labels = Nx.select(person, Nx.u8(4), Nx.u8(0))
    # foreground COMPLETO (pessoa + estrutura), como o U²-Net cru (todos os comps)
    fg = Nx.logical_or(person, extra) |> Nx.multiply(255) |> Nx.as_type(:u8)
    {fg, labels}
  end

  test "detect/2 isola a estrutura ALTA e VERTICAL (tecido), descartando a pessoa" do
    # mecha vertical: 20 de largura × 170 de altura (85% do quadro), longe da pessoa
    {fg, labels} = scene({0, 170, 110, 130})

    mask = Apparatus.detect(fg, labels)

    assert Nx.shape(mask) == {200, 200}
    # corpo da mecha vira máscara…
    assert Nx.to_number(mask[80][120]) == 255
    # …e a pessoa NÃO (subtraída, e não é alta/vertical)
    assert Nx.to_number(mask[110][65]) == 0
  end

  test "detect/2 ignora estrutura BAIXA e LARGA (não é tecido)" do
    # faixa larga e baixa: 100 de largura × 20 de altura — não passa no 'alto'
    {fg, labels} = scene({20, 40, 50, 150})

    mask = Apparatus.detect(fg, labels)
    assert Nx.to_number(Nx.sum(Nx.greater(mask, 0))) == 0
  end

  test "into_labels/2 injeta a classe 19 só onde há tecido E o ATR não rotulou" do
    {fg, labels} = scene({0, 170, 110, 130})
    mask = Apparatus.detect(fg, labels)

    augmented = Apparatus.into_labels(labels, mask)

    assert Nx.to_number(augmented[80][120]) == 19
    assert Nx.to_number(augmented[110][65]) == 4
  end

  test "detect/4 acha o tecido pela COR mesmo quando o U²-Net não o vê" do
    rows = Nx.iota({200, 200}, axis: 0)
    cols = Nx.iota({200, 200}, axis: 1)
    # faixa vertical vermelha (o tecido) sobre fundo cinza
    band =
      Nx.logical_and(Nx.greater_equal(cols, 95), Nx.less(cols, 115))
      |> Nx.logical_and(Nx.less(rows, 170))

    red = Nx.tensor([220, 30, 40], type: :u8) |> Nx.broadcast({200, 200, 3})
    gray = Nx.broadcast(Nx.u8(128), {200, 200, 3})
    rgb = Nx.select(Nx.broadcast(Nx.new_axis(band, -1), {200, 200, 3}), red, gray)

    fg = Nx.broadcast(Nx.u8(0), {200, 200})
    labels = Nx.broadcast(Nx.u8(0), {200, 200})

    # sem cor + sem foreground → nada
    assert Nx.to_number(Nx.sum(Apparatus.detect(fg, labels))) == 0
    # com a cor do tecido → acha a faixa vermelha (a pista que o usuário indica)
    mask = Apparatus.detect(fg, labels, rgb, {220, 30, 40})
    assert Nx.to_number(mask[80][105]) == 255
  end

  test "detect/4 NÃO rouba o cabelo da mesma cor do tecido (regressão: cabelo rosa)" do
    rows = Nx.iota({200, 200}, axis: 0)
    cols = Nx.iota({200, 200}, axis: 1)

    rect = fn r0, r1, c0, c1 ->
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, r0), Nx.less(rows, r1)),
        Nx.logical_and(Nx.greater_equal(cols, c0), Nx.less(cols, c1))
      )
    end

    # tecido: faixa vertical vermelha alta. cabelo: blob vermelho (MESMA cor) colado
    # na faixa. O ATR só rotula o NÚCLEO do cabelo (classe 2); a borda do cabelo é
    # vermelha mas fica como fundo (0) — é o que o SegFormer sub-segmenta na vida real.
    band = rect.(0, 170, 100, 120)
    hair_blob = rect.(15, 45, 75, 100)
    hair_core = rect.(22, 40, 80, 97)

    red_region = Nx.logical_or(band, hair_blob)
    red = Nx.tensor([220, 30, 40], type: :u8) |> Nx.broadcast({200, 200, 3})
    gray = Nx.broadcast(Nx.u8(128), {200, 200, 3})
    rgb = Nx.select(Nx.broadcast(Nx.new_axis(red_region, -1), {200, 200, 3}), red, gray)

    fg = red_region |> Nx.multiply(255) |> Nx.as_type(:u8)
    labels = Nx.select(hair_core, Nx.u8(2), Nx.u8(0))

    mask = Apparatus.detect(fg, labels, rgb, {220, 30, 40})

    # o tecido (faixa, longe do cabelo) continua sendo detectado
    assert Nx.to_number(mask[120][110]) == 255
    # a borda vermelha do cabelo (rótulo 0, junto do núcleo class 2) NÃO vira tecido
    assert Nx.to_number(mask[16][80]) == 0
  end
end
