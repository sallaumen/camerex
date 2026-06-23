defmodule Camerex.Parser.PersonFillTest do
  use ExUnit.Case, async: true

  alias Camerex.Parser.{LayerContext, PersonFill}

  # Cena 200×200: BLOCO de corpo-ATR (classe 14 = braço) com um BURACO interno
  # (classe 0) que a silhueta SOD cobre; e uma FITA vertical fina (aparelho) que
  # sai do topo do bloco — coberta pela silhueta, mas o ATR não a viu.
  defp scene do
    w = 200
    rows = Nx.iota({w, w}, axis: 0)
    cols = Nx.iota({w, w}, axis: 1)

    rect = fn {r0, r1, c0, c1} ->
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, r0), Nx.less(rows, r1)),
        Nx.logical_and(Nx.greater_equal(cols, c0), Nx.less(cols, c1))
      )
    end

    person = rect.({60, 140, 40, 120})
    hole = rect.({85, 115, 60, 100})
    # fita 8px de largura, 50px de altura (aspect ~6 > 4) colada no topo do corpo
    ribbon = rect.({12, 62, 72, 80})

    labels = Nx.select(Nx.logical_and(person, Nx.logical_not(hole)), Nx.u8(14), Nx.u8(0))
    fg = person |> Nx.logical_or(ribbon) |> Nx.multiply(255) |> Nx.as_type(:u8)
    {labels, fg}
  end

  test "preenche o buraco interno colado na pessoa com a classe de corpo vizinha (14)" do
    {labels, fg} = scene()
    mask = PersonFill.run(%LayerContext{fg: fg, labels: labels})
    out = PersonFill.into_labels(labels, mask)
    # centro do buraco (era 0) herda o braço vizinho (14)
    assert Nx.to_number(out[100][80]) == 14
  end

  test "a FITA (aparelho vertical fino) NÃO é preenchida — fica fundo" do
    {labels, fg} = scene()
    mask = PersonFill.run(%LayerContext{fg: fg, labels: labels})
    out = PersonFill.into_labels(labels, mask)
    # centro da fita continua 0 (descartada pelo filtro de fita/aspect)
    assert Nx.to_number(out[36][76]) == 0
  end

  test "into_labels só toca FUNDO — corpo já rotulado fica intacto" do
    {labels, fg} = scene()
    mask = PersonFill.run(%LayerContext{fg: fg, labels: labels})
    out = PersonFill.into_labels(labels, mask)
    # um pixel de braço (14) fora do buraco continua 14
    assert Nx.to_number(out[70][50]) == 14
  end

  test "sem silhueta (fg nil) → máscara vazia (no-op)" do
    {labels, _fg} = scene()
    assert Nx.to_number(Nx.sum(PersonFill.run(%LayerContext{fg: nil, labels: labels}))) == 0
  end
end
