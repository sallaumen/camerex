defmodule Camerex.EvalTest do
  use ExUnit.Case, async: true

  alias Camerex.Eval

  describe "contact_sheet/2" do
    test "monta grid de `cols` colunas, padroniza altura e preenche a última linha" do
      a = Nx.broadcast(Nx.u8(10), {2, 3, 3})
      b = Nx.broadcast(Nx.u8(20), {4, 3, 3})
      c = Nx.broadcast(Nx.u8(30), {3, 3, 3})

      sheet = Eval.contact_sheet([a, b, c], 2)

      # 3 tiles, 2 colunas → 2 linhas; row_h = 4 (maior); largura = 2×3 = 6
      assert Nx.shape(sheet) == {8, 6, 3}
      assert Nx.type(sheet) == {:u, 8}
    end

    test "1 tile, 1 coluna = o próprio tile" do
      a = Nx.broadcast(Nx.u8(7), {5, 4, 3})
      assert Eval.contact_sheet([a], 1) == a
    end
  end

  describe "class_counts/1" do
    test "conta px por grupo semântico do Layers" do
      # cabelo(2)×2, rosto(11, grupo pele)×1, roupa(4)×1
      labels = Nx.tensor([[2, 2, 4], [11, 0, 0]], type: :u8)

      counts = Eval.class_counts(labels)

      assert counts.hair == 2
      assert counts.skin == 1
      assert counts.clothing == 1
      assert counts.apparatus == 0
    end
  end
end
