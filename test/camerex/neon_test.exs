defmodule Camerex.NeonTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Camerex.Neon
  alias Camerex.Neon.Palette

  # quadrado branco 32x32 (linhas/colunas 16..47) em fundo preto 64x64, RGB
  defp square_scene do
    rows = Nx.iota({64, 64}, axis: 0)
    cols = Nx.iota({64, 64}, axis: 1)

    inside =
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, 16), Nx.less(rows, 48)),
        Nx.logical_and(Nx.greater_equal(cols, 16), Nx.less(cols, 48))
      )

    rgb =
      inside
      |> Nx.multiply(255)
      |> Nx.as_type(:u8)
      |> Nx.new_axis(-1)
      |> Nx.broadcast({64, 64, 3})

    {rgb, Nx.broadcast(Nx.u8(255), {64, 64})}
  end

  describe "trace_edges/3" do
    test "quadrado branco com máscara cheia: bordas no perímetro, nada longe dele" do
      {rgb, mask} = square_scene()

      edges = Neon.trace_edges(rgb, mask)

      assert Nx.shape(edges) == {64, 64}
      assert Nx.type(edges) == {:u, 8}

      # bandas em volta de cada lado do quadrado contêm borda...
      assert edges[[14..18, 20..44]] |> Nx.sum() |> Nx.to_number() > 0
      assert edges[[45..49, 20..44]] |> Nx.sum() |> Nx.to_number() > 0
      assert edges[[20..44, 14..18]] |> Nx.sum() |> Nx.to_number() > 0
      assert edges[[20..44, 45..49]] |> Nx.sum() |> Nx.to_number() > 0

      # ...e longe da borda não há nada
      assert Nx.to_number(edges[32][32]) == 0
      assert Nx.to_number(edges[2][2]) == 0
    end

    test "saída binária 0|255" do
      {rgb, mask} = square_scene()

      uniq =
        Neon.trace_edges(rgb, mask)
        |> Nx.to_flat_list()
        |> Enum.uniq()
        |> Enum.sort()

      assert uniq == [0, 255]
    end

    test "default detail: 0.5 equivale ao explícito (canny 60/140)" do
      {rgb, mask} = square_scene()

      assert Nx.to_binary(Neon.trace_edges(rgb, mask)) ==
               Nx.to_binary(Neon.trace_edges(rgb, mask, detail: 0.5))
    end
  end

  describe "mask_median_x/1" do
    test "mediana com contagem ímpar de pixels" do
      mask =
        Nx.tensor(
          [
            [0, 255, 0, 255, 0, 0, 255, 0],
            [0, 0, 0, 0, 0, 0, 0, 0]
          ],
          type: :u8
        )

      # xs = [1, 3, 6] → mediana 3.0
      assert Neon.mask_median_x(mask) == 3.0
    end

    test "contagem par tira a média dos dois centrais (como np.median)" do
      mask =
        Nx.tensor(
          [
            [255, 0, 255, 0, 0, 255, 0, 255],
            [0, 0, 0, 0, 0, 0, 0, 0]
          ],
          type: :u8
        )

      # xs = [0, 2, 5, 7] → (2 + 5) / 2 = 3.5
      assert Neon.mask_median_x(mask) == 3.5
    end

    test "máscara vazia devolve w/2" do
      assert Neon.mask_median_x(Nx.broadcast(Nx.u8(0), {6, 8})) == 4.0
    end
  end

  describe "trace_edges/3 — borda por cor (chroma)" do
    # quadrado saturado sobre fundo cinza de MESMA luminância: invisível no
    # cinza (Canny de luminância cego), mas óbvio na saturação
    defp chroma_scene do
      rows = Nx.iota({32, 32}, axis: 0)
      cols = Nx.iota({32, 32}, axis: 1)

      inside =
        Nx.logical_and(
          Nx.logical_and(Nx.greater_equal(rows, 10), Nx.less(rows, 22)),
          Nx.logical_and(Nx.greater_equal(cols, 10), Nx.less(cols, 22))
        )

      # fundo (81,81,81) luma≈81; quadrado (200,30,30) luma≈81, mas S alta
      bg = Nx.tensor([81, 81, 81], type: :u8) |> Nx.broadcast({32, 32, 3})
      sq = Nx.tensor([200, 30, 30], type: :u8) |> Nx.broadcast({32, 32, 3})
      rgb = Nx.select(Nx.new_axis(inside, -1) |> Nx.broadcast({32, 32, 3}), sq, bg)
      {rgb, Nx.broadcast(Nx.u8(255), {32, 32})}
    end

    test "chroma: default 0.0 é idêntico a não passar chroma" do
      {rgb, mask} = chroma_scene()

      assert Nx.to_binary(Neon.trace_edges(rgb, mask)) ==
               Nx.to_binary(Neon.trace_edges(rgb, mask, chroma: 0.0))
    end

    test "chroma > 0 recupera a borda de cor que o cinza não vê" do
      {rgb, mask} = chroma_scene()

      sem = Neon.trace_edges(rgb, mask, chroma: 0.0) |> Nx.sum() |> Nx.to_number()
      com = Neon.trace_edges(rgb, mask, chroma: 0.8) |> Nx.sum() |> Nx.to_number()

      assert com > sem
    end
  end

  describe "mask_y_bounds/1" do
    test "linhas acesas 2..5 numa máscara 8x8" do
      mask =
        Nx.broadcast(Nx.u8(0), {8, 8})
        |> Nx.put_slice([2, 0], Nx.broadcast(Nx.u8(255), {4, 8}))

      assert Neon.mask_y_bounds(mask) == {2, 5}
    end

    test "máscara vazia devolve a moldura inteira" do
      assert Neon.mask_y_bounds(Nx.broadcast(Nx.u8(0), {10, 4})) == {0, 9}
    end
  end

  describe "vertical_weights/4" do
    test "rampa: 0 no topo, 1 na base, constante por coluna" do
      w = Neon.vertical_weights(10, 3, 0, 9)

      assert Nx.shape(w) == {10, 3}
      assert Nx.type(w) == {:f, 32}
      assert Nx.to_number(w[0][0]) == 0.0
      assert Nx.to_number(w[9][2]) == 1.0
      assert Nx.to_number(w[0][0]) == Nx.to_number(w[0][2])
    end

    test "monotônica nas linhas e fora do intervalo é clampada" do
      w = Neon.vertical_weights(6, 1, 2, 4)
      col = w[[.., 0]] |> Nx.to_flat_list()

      assert col == Enum.sort(col)
      assert List.first(col) == 0.0
      assert List.last(col) == 1.0
    end
  end

  describe "duotone_weights/4" do
    test "sigmoide: 0.5 no split, ~0 bem à esquerda, ~1 bem à direita" do
      w = Neon.duotone_weights(2, 200, 100.0, 24)

      assert Nx.shape(w) == {2, 200}
      assert Nx.type(w) == {:f, 32}
      assert_in_delta Nx.to_number(w[0][100]), 0.5, 1.0e-6
      assert Nx.to_number(w[0][0]) < 0.02
      assert Nx.to_number(w[0][199]) > 0.98
    end

    test "monotônica em x" do
      vals = Neon.duotone_weights(1, 64, 32.0, 24) |> Nx.to_flat_list()
      assert vals == Enum.sort(vals)
    end
  end

  describe "compose/3" do
    property "mono: pixel com edges == 1.0 sai na cor exata do preset" do
      check all(
              bits <- list_of(integer(0..1), length: 64),
              preset_id <- member_of(~w(forro-laranja forro-teal ouro)),
              halo <- float(min: 0.0, max: 1.0)
            ) do
        edges = bits |> Nx.tensor(type: :f32) |> Nx.reshape({8, 8})
        %{colors: [{r, g, b}] = colors} = Palette.get(preset_id)

        out = Neon.compose(edges, colors, halo: halo)

        for i <- 0..7, j <- 0..7, Enum.at(bits, i * 8 + j) == 1 do
          assert Nx.to_number(out[i][j][0]) == r
          assert Nx.to_number(out[i][j][1]) == g
          assert Nx.to_number(out[i][j][2]) == b
        end
      end
    end

    test "máximo, nunca soma: linha + halos sobrepostos não passam da cor" do
      # tudo aceso com halo máximo: se compose somasse, os canais passariam
      # da cor (43 * (1 + 1.0 + 0.92) = 125...); por máximo, saem exatos
      edges = Nx.broadcast(Nx.tensor(1.0, type: :f32), {8, 8})

      out = Neon.compose(edges, [{43, 196, 178}], halo: 1.0)

      expected = Nx.broadcast(Nx.tensor([43, 196, 178], type: :u8), {8, 8, 3})
      assert Nx.to_flat_list(out) == Nx.to_flat_list(expected)
    end

    test "halo: vizinho da linha brilha menos que a linha; máximo global == cor" do
      line = Nx.broadcast(Nx.tensor(1.0, type: :f32), {1, 16})

      edges =
        Nx.broadcast(Nx.tensor(0.0, type: :f32), {16, 16})
        |> Nx.put_slice([4, 0], line)

      out = Neon.compose(edges, [{43, 196, 178}], halo: 0.6)

      assert Nx.to_number(out[4][8][1]) == 196
      assert Nx.to_number(out[6][8][1]) in 1..195
      assert out[[.., .., 1]] |> Nx.reduce_max() |> Nx.to_number() == 196
    end

    test "duotone: pesos 0 / 1 / 0.5 interpolam a cor exatamente" do
      edges = Nx.broadcast(Nx.tensor(1.0, type: :f32), {4, 4})
      colors = [{255, 138, 92}, {43, 196, 178}]

      out0 =
        Neon.compose(edges, colors,
          duotone_weights: Nx.broadcast(Nx.tensor(0.0, type: :f32), {4, 4})
        )

      out1 =
        Neon.compose(edges, colors,
          duotone_weights: Nx.broadcast(Nx.tensor(1.0, type: :f32), {4, 4})
        )

      outh =
        Neon.compose(edges, colors,
          duotone_weights: Nx.broadcast(Nx.tensor(0.5, type: :f32), {4, 4})
        )

      assert Nx.to_flat_list(out0[0][0]) == [255, 138, 92]
      assert Nx.to_flat_list(out1[0][0]) == [43, 196, 178]
      # 0.5: (255+43)/2 = 149, (138+196)/2 = 167, (92+178)/2 = 135
      assert Nx.to_flat_list(outh[0][0]) == [149, 167, 135]
    end

    test "bloom: default 0.0 é idêntico a não passar bloom" do
      edges =
        Nx.broadcast(Nx.tensor(0.0, type: :f32), {16, 16})
        |> Nx.put_slice([8, 8], Nx.tensor([[1.0]], type: :f32))

      sem = Neon.compose(edges, [{43, 196, 178}], halo: 0.6)
      com_zero = Neon.compose(edges, [{43, 196, 178}], halo: 0.6, bloom: 0.0)

      assert Nx.to_binary(sem) == Nx.to_binary(com_zero)
    end

    test "bloom: adiciona brilho longe da linha sem estourar a cor" do
      edges =
        Nx.broadcast(Nx.tensor(0.0, type: :f32), {32, 32})
        |> Nx.put_slice([16, 0], Nx.broadcast(Nx.tensor(1.0, type: :f32), {1, 32}))

      sem = Neon.compose(edges, [{43, 196, 178}], halo: 0.3, bloom: 0.0)
      com = Neon.compose(edges, [{43, 196, 178}], halo: 0.3, bloom: 0.9)

      # bem longe da linha (10 px acima), o bloom acende o que estava apagado
      assert Nx.to_number(com[6][16][1]) > Nx.to_number(sem[6][16][1])
      # a linha continua exatamente na cor (máximo nunca estoura)
      assert Nx.to_number(com[16][16][1]) == 196
      assert com[[.., .., 1]] |> Nx.reduce_max() |> Nx.to_number() == 196
    end

    test "gradiente 3 paradas: pesos 0 / 0.5 / 1 interpolam por segmento" do
      edges = Nx.broadcast(Nx.tensor(1.0, type: :f32), {4, 4})
      colors = [{0, 0, 0}, {100, 100, 100}, {200, 200, 200}]

      out = fn wv ->
        Neon.compose(edges, colors,
          duotone_weights: Nx.broadcast(Nx.tensor(wv, type: :f32), {4, 4})
        )
      end

      assert Nx.to_flat_list(out.(0.0)[0][0]) == [0, 0, 0]
      assert Nx.to_flat_list(out.(0.5)[0][0]) == [100, 100, 100]
      assert Nx.to_flat_list(out.(1.0)[0][0]) == [200, 200, 200]
      # 0.25 cai no meio do 1º segmento → meio de preto..cinza-médio = 50
      assert Nx.to_flat_list(out.(0.25)[0][0]) == [50, 50, 50]
    end

    test "current_edges substitui o input na camada de linha nítida (vídeo)" do
      trail = Nx.broadcast(Nx.tensor(0.0, type: :f32), {8, 8})
      current = Nx.put_slice(trail, [4, 4], Nx.tensor([[1.0]], type: :f32))

      out = Neon.compose(trail, [{255, 209, 102}], current_edges: current)

      assert Nx.to_flat_list(out[4][4]) == [255, 209, 102]
      assert Nx.to_flat_list(out[0][0]) == [0, 0, 0]
    end
  end
end
