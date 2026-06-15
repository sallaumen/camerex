defmodule Camerex.Neon.LayeredTest do
  use ExUnit.Case, async: true

  alias Camerex.Neon.Layered
  alias Camerex.Parser.Layers

  # bloco cheio de um rótulo dentro de um campo de fundo (0)
  defp block_labels(h, w, id, {r0, r1, c0, c1}) do
    rows = Nx.iota({h, w}, axis: 0)
    cols = Nx.iota({h, w}, axis: 1)

    inside =
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, r0), Nx.less(rows, r1)),
        Nx.logical_and(Nx.greater_equal(cols, c0), Nx.less(cols, c1))
      )

    Nx.select(inside, id, 0) |> Nx.as_type(:u8)
  end

  defp flat(h, w), do: Nx.broadcast(Nx.u8(127), {h, w, 3})

  describe "line_art/3" do
    test "traça o CONTORNO da parte: borda acesa, interior apagado" do
      # bloco de roupa (4) rows 15..44, cols 15..44 num 60x60; rgb liso → sem
      # detalhe interno, só o contorno
      labels = block_labels(60, 60, 4, {15, 45, 15, 45})
      line = Layered.line_art(flat(60, 60), labels, detail: 0.5)

      assert Nx.shape(line) == {60, 60}
      assert Nx.type(line) == {:f, 32}

      # interior (bem longe da borda) totalmente apagado — é arte-de-linha,
      # não preenchimento
      assert line[[25..34, 25..34]] |> Nx.sum() |> Nx.to_number() == 0.0
      # mas há contorno em algum lugar, em [0, 1]
      assert line |> Nx.sum() |> Nx.to_number() > 0.0
      assert Nx.to_number(Nx.reduce_max(line)) <= 1.0
    end

    test "detail > 0 traz detalhe interno que detail: 0 (só contornos) não tem" do
      labels = block_labels(60, 60, 4, {10, 50, 10, 50})

      # borda de luminância forte DENTRO da parte (metade escura, metade clara)
      cols = Nx.iota({60, 60}, axis: 1)
      half = Nx.select(Nx.less(cols, 30), 40, 210) |> Nx.as_type(:u8)
      rgb = half |> Nx.new_axis(-1) |> Nx.broadcast({60, 60, 3})

      so_contorno = Layered.line_art(rgb, labels, detail: 0.0) |> Nx.sum() |> Nx.to_number()
      com_detalhe = Layered.line_art(rgb, labels, detail: 0.6) |> Nx.sum() |> Nx.to_number()

      assert com_detalhe > so_contorno
    end

    test "sem nenhuma parte (labels só fundo) → tudo zero" do
      empty = Nx.broadcast(Nx.u8(0), {40, 40})

      assert Layered.line_art(flat(40, 40), empty, detail: 0.5)
             |> Nx.sum()
             |> Nx.to_number() == 0.0
    end

    test "descarta ilhas de rotulagem (componente minúsculo não vira contorno)" do
      # bloco grande de roupa + speck 3x3 isolado do MESMO rótulo, num 200x200
      big = block_labels(200, 200, 4, {40, 160, 40, 160})
      speck = block_labels(200, 200, 4, {10, 13, 10, 13})
      labels = Nx.max(big, speck)

      line = Layered.line_art(flat(200, 200), labels, detail: 0.0)

      # ao redor do speck não há contorno (área < min_area → descartado)
      assert line[[4..18, 4..18]] |> Nx.sum() |> Nx.to_number() == 0.0
      # o bloco grande tem contorno
      assert line |> Nx.sum() |> Nx.to_number() > 0.0
    end
  end

  describe "color_field/3" do
    # topo = roupa (4 → teal frio), base = cabelo (2 → laranja quente)
    defp duo_labels do
      rows = Nx.iota({40, 40}, axis: 0)
      Nx.select(Nx.less(rows, 20), 4, 2) |> Nx.as_type(:u8)
    end

    test "mescla por grupo: topo puxa teal (G>R), base puxa laranja (R>B)" do
      field = Layered.color_field(duo_labels(), Layers.default_colors(), 40)

      assert Nx.shape(field) == {40, 40, 3}

      topo = field[[2, 20]]
      base = field[[37, 20]]

      # teal {43,196,178}: verde domina o vermelho
      assert Nx.to_number(topo[1]) > Nx.to_number(topo[0])
      # laranja {255,90,30}: vermelho domina o azul
      assert Nx.to_number(base[0]) > Nx.to_number(base[2])
    end

    test "as cores se misturam na fronteira (não há borda dura)" do
      field = Layered.color_field(duo_labels(), Layers.default_colors(), 40)

      # vermelho cresce monotonicamente do topo (teal, R baixo) p/ base (laranja)
      r_topo = Nx.to_number(field[[2, 20, 0]])
      r_meio = Nx.to_number(field[[20, 20, 0]])
      r_base = Nx.to_number(field[[37, 20, 0]])

      assert r_topo < r_meio
      assert r_meio < r_base
    end

    test "layer_colors sobrescreve a cor de um grupo (roupa azul)" do
      field = Layered.color_field(duo_labels(), %{clothing: {0, 0, 255}}, 40)

      topo = field[[2, 20]]
      assert Nx.to_number(topo[2]) > Nx.to_number(topo[0])
    end

    test "sem nenhuma parte → campo preto" do
      empty = Nx.broadcast(Nx.u8(0), {30, 30})

      assert Layered.color_field(empty, Layers.default_colors(), 30)
             |> Nx.sum()
             |> Nx.to_number() == 0.0
    end
  end
end
