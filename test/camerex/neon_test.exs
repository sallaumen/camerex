defmodule Camerex.NeonTest do
  use ExUnit.Case, async: true

  alias Camerex.Neon

  # campo de cor sólido {h,w,3} f32 de uma cor (cor-por-parte injeta o campo)
  defp solid(h, w, {r, g, b}) do
    Nx.tensor([r, g, b], type: :f32) |> Nx.reshape({1, 1, 3}) |> Nx.broadcast({h, w, 3})
  end

  describe "compose/2 (cor-por-parte)" do
    test "linha cheia sai na cor exata do campo (halo 0); devolve {h,w,3} u8" do
      input = Nx.broadcast(1.0, {8, 8})
      out = Neon.compose(input, halo: 0.0, bloom: 0.0, color_field: solid(8, 8, {40, 200, 180}))

      assert Nx.shape(out) == {8, 8, 3}
      assert Nx.type(out) == {:u, 8}
      assert Nx.to_flat_list(out[0][0]) == [40, 200, 180]
    end

    test "halo espalha: vizinho da linha acende, mas mais fraco que a linha" do
      h = w = 24
      input = Nx.iota({h, w}, axis: 1) |> Nx.equal(12) |> Nx.as_type(:f32)
      out = Neon.compose(input, halo: 0.6, bloom: 0.0, color_field: solid(h, w, {40, 200, 180}))

      linha = Nx.to_number(out[12][12][1])
      vizinho = Nx.to_number(out[12][16][1])
      assert vizinho > 0 and vizinho < linha
    end

    test "current_edges substitui o input na camada de linha nítida (vídeo)" do
      out =
        Neon.compose(Nx.broadcast(0.0, {8, 8}),
          halo: 0.0,
          bloom: 0.0,
          color_field: solid(8, 8, {40, 200, 180}),
          current_edges: Nx.broadcast(1.0, {8, 8})
        )

      assert Nx.to_flat_list(out[0][0]) == [40, 200, 180]
    end
  end
end
