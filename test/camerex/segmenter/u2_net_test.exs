defmodule Camerex.Segmenter.U2NetTest do
  use ExUnit.Case, async: true

  alias Camerex.Segmenter.U2Net

  describe "preprocess/1" do
    test "shape e normalização de um 4x4 constante (valores calculados à mão)" do
      # pixel constante (255, 128, 0). Após t / max(reduce_max(t), 1.0e-6):
      # (1.0, 128/255, 0.0). Após (t - mean) / std por canal:
      #   R: (1.0     - 0.485) / 0.229 = 0.515   / 0.229 ≈  2.24891
      #   G: (128/255 - 0.456) / 0.224 = 0.04596 / 0.224 ≈  0.20518
      #   B: (0.0     - 0.406) / 0.225 =                  ≈ -1.80444
      rgb = Nx.broadcast(Nx.tensor([255, 128, 0], type: :u8), {4, 4, 3})

      out = U2Net.preprocess(rgb)

      assert Nx.shape(out) == {1, 3, 320, 320}
      assert Nx.type(out) == {:f, 32}

      assert_in_delta Nx.to_number(out[0][0][0][0]), 2.24891, 1.0e-3
      assert_in_delta Nx.to_number(out[0][1][0][0]), 0.20518, 1.0e-3
      assert_in_delta Nx.to_number(out[0][2][0][0]), -1.80444, 1.0e-3

      # constante na imagem inteira: o canal todo tem o mesmo valor
      assert_in_delta out[0][0] |> Nx.reduce_min() |> Nx.to_number(), 2.24891, 1.0e-3
      assert_in_delta out[0][0] |> Nx.reduce_max() |> Nx.to_number(), 2.24891, 1.0e-3
    end

    test "imagem toda preta não divide por zero (guarda 1.0e-6)" do
      rgb = Nx.broadcast(Nx.u8(0), {4, 4, 3})

      out = U2Net.preprocess(rgb)

      # 0 / 1.0e-6 = 0.0 → (0 - mean) / std por canal
      assert_in_delta Nx.to_number(out[0][0][0][0]), -0.485 / 0.229, 1.0e-3
      assert_in_delta Nx.to_number(out[0][1][0][0]), -0.456 / 0.224, 1.0e-3
      assert_in_delta Nx.to_number(out[0][2][0][0]), -0.406 / 0.225, 1.0e-3
    end
  end

  describe "postprocess/2" do
    defp half_d0 do
      left = Nx.broadcast(Nx.tensor(0.2, type: :f32), {1, 1, 320, 160})
      right = Nx.broadcast(Nx.tensor(0.7, type: :f32), {1, 1, 320, 160})
      Nx.concatenate([left, right], axis: 3)
    end

    test "min-max + escala: 0.2 vira 0 e 0.7 vira 255 (mesmo tamanho)" do
      out = U2Net.postprocess(half_d0(), {320, 320})

      assert Nx.shape(out) == {320, 320}
      assert Nx.type(out) == {:u, 8}
      assert Nx.to_number(out[0][0]) == 0
      assert Nx.to_number(out[0][319]) == 255
    end

    test "redimensiona para o {h, w} pedido" do
      out = U2Net.postprocess(half_d0(), {64, 32})

      assert Nx.shape(out) == {64, 32}
      # cantos longe da emenda: regiões constantes sobrevivem ao LANCZOS4
      assert Nx.to_number(out[0][0]) == 0
      assert Nx.to_number(out[0][31]) == 255
    end
  end

  describe "binarize/1" do
    test "limiar alpha > 30 do contrato §4 (30 fica fora, 31 entra)" do
      alpha = Nx.tensor([[0, 30, 31, 255]], type: :u8)

      out = U2Net.binarize(alpha)

      assert Nx.type(out) == {:u, 8}
      assert Nx.to_flat_list(out) == [0, 0, 255, 255]
    end
  end
end
