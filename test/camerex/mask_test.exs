defmodule Camerex.MaskTest do
  use ExUnit.Case, async: true

  alias Camerex.Mask

  # dois blobs: A 3x3 (área 9) no topo-esquerdo, B 2x2 (área 4) embaixo-direita
  defp two_blobs do
    Nx.tensor(
      [
        [255, 255, 255, 0, 0, 0, 0, 0],
        [255, 255, 255, 0, 0, 0, 0, 0],
        [255, 255, 255, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 255, 255, 0],
        [0, 0, 0, 0, 0, 255, 255, 0],
        [0, 0, 0, 0, 0, 0, 0, 0]
      ],
      type: :u8
    )
  end

  defp blob_a_only do
    Nx.tensor(
      [
        [255, 255, 255, 0, 0, 0, 0, 0],
        [255, 255, 255, 0, 0, 0, 0, 0],
        [255, 255, 255, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0]
      ],
      type: :u8
    )
  end

  defp blob_b_only do
    Nx.tensor(
      [
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 255, 255, 0],
        [0, 0, 0, 0, 0, 255, 255, 0],
        [0, 0, 0, 0, 0, 0, 0, 0]
      ],
      type: :u8
    )
  end

  # máscara anterior cobrindo só o quadrante do blob B (o menor)
  defp prev_over_b do
    Nx.tensor(
      [
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 255, 255, 255, 255],
        [0, 0, 0, 0, 255, 255, 255, 255],
        [0, 0, 0, 0, 255, 255, 255, 255],
        [0, 0, 0, 0, 255, 255, 255, 255]
      ],
      type: :u8
    )
  end

  describe "largest_component/1" do
    test "mantém só o maior blob" do
      assert Nx.to_flat_list(Mask.largest_component(two_blobs())) ==
               Nx.to_flat_list(blob_a_only())
    end

    test "máscara vazia volta intacta" do
      empty = Nx.broadcast(Nx.u8(0), {8, 8})

      assert Nx.to_flat_list(Mask.largest_component(empty)) ==
               Nx.to_flat_list(empty)
    end
  end

  describe "consistent_component/2" do
    test "sem máscara anterior delega para o maior componente" do
      assert Nx.to_flat_list(Mask.consistent_component(two_blobs(), nil)) ==
               Nx.to_flat_list(blob_a_only())
    end

    test "sobreposição vence área: anterior sobre o blob menor escolhe o menor" do
      # scores (contrato §4): A = 0 + 1.0e-4 * 9; B = 4 + 1.0e-4 * 4 → B vence
      assert Nx.to_flat_list(Mask.consistent_component(two_blobs(), prev_over_b())) ==
               Nx.to_flat_list(blob_b_only())
    end

    test "sem sobreposição nenhuma, a área desempata para o maior" do
      prev = Nx.broadcast(Nx.u8(0), {8, 8})

      assert Nx.to_flat_list(Mask.consistent_component(two_blobs(), prev)) ==
               Nx.to_flat_list(blob_a_only())
    end
  end

  describe "ema/3" do
    test "sem anterior devolve o frame atual" do
      curr = Nx.broadcast(Nx.tensor(0.8, type: :f32), {4, 4})
      assert Nx.to_flat_list(Mask.ema(curr, nil)) == Nx.to_flat_list(curr)
    end

    test "alpha é o peso do ANTERIOR: 0.45*prev + 0.55*curr" do
      curr = Nx.broadcast(Nx.tensor(1.0, type: :f32), {4, 4})
      prev = Nx.broadcast(Nx.tensor(0.0, type: :f32), {4, 4})

      assert_in_delta Nx.to_number(Mask.ema(curr, prev, 0.45)[0][0]), 0.55, 1.0e-6
      assert_in_delta Nx.to_number(Mask.ema(curr, prev, 0.8)[0][0]), 0.2, 1.0e-6
    end

    test "alpha default é 0.45" do
      curr = Nx.broadcast(Nx.tensor(1.0, type: :f32), {4, 4})
      prev = Nx.broadcast(Nx.tensor(0.5, type: :f32), {4, 4})

      assert Nx.to_flat_list(Mask.ema(curr, prev)) ==
               Nx.to_flat_list(Mask.ema(curr, prev, 0.45))
    end
  end
end
