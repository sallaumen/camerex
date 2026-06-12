defmodule Camerex.NeonTest do
  use ExUnit.Case, async: true

  alias Camerex.Neon

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
end
