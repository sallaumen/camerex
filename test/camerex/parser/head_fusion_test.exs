defmodule Camerex.Parser.HeadFusionTest do
  use ExUnit.Case, async: true

  alias Camerex.Parser.HeadFusion
  alias Camerex.Parser.LayerContext

  describe "combine/3 (fusão pura da cabeça)" do
    test "cabelo→2, rosto→11, ambos confinados à âncora pessoa; cabelo manda na sobreposição" do
      # pessoa = quadrante superior-esquerdo 2x2
      person = Nx.tensor([[1, 1, 0], [1, 1, 0], [0, 0, 0]], type: :u8)
      # cabelo só em (0,0)
      hair = Nx.tensor([[1, 0, 0], [0, 0, 0], [0, 0, 0]], type: :u8)
      # rosto em (0,0) [sobrepõe cabelo], (0,1) [dentro], (1,2) [FORA da pessoa]
      face = Nx.tensor([[1, 1, 0], [0, 0, 1], [0, 0, 0]], type: :u8)

      mask = HeadFusion.combine(hair, face, person)

      assert Nx.type(mask) == {:u, 8}
      # (0,0) cabelo vence rosto → 2; (0,1) rosto dentro → 11; (1,2) rosto fora → 0
      assert Nx.to_flat_list(mask) == [2, 11, 0, 0, 0, 0, 0, 0, 0]
    end

    test "nada dentro da pessoa → máscara toda zero" do
      person = Nx.broadcast(Nx.u8(0), {3, 3})
      hair = Nx.broadcast(Nx.u8(1), {3, 3})
      face = Nx.broadcast(Nx.u8(1), {3, 3})

      assert HeadFusion.combine(hair, face, person) |> Nx.sum() |> Nx.to_number() == 0
    end
  end

  describe "into_labels/2" do
    test "injeta a cabeça só onde o ATR deixou FUNDO (não sobrescreve roupa)" do
      # (0,1) é roupa (4); o resto é fundo (0)
      labels = Nx.tensor([[0, 4, 0], [0, 0, 0]], type: :u8)
      # cabeça quer pintar (0,0)=cabelo, (0,1)=cabelo [mas é roupa], (1,0)=rosto
      mask = Nx.tensor([[2, 2, 0], [11, 0, 0]], type: :u8)

      out = HeadFusion.into_labels(labels, mask)

      # (0,0) fundo→2; (0,1) roupa fica 4 (não sobrescreve); (1,0) fundo→11
      assert Nx.to_flat_list(out) == [2, 4, 0, 11, 0, 0]
    end

    test "reivindica classes de Acessório (bag=16, óculos=3) sob a máscara, preservando roupa real e acessório fora" do
      # na pose invertida o ATR rotula o cabelo como bag(16) e o rosto como óculos(3).
      # (0,0)=bag misfire, (0,1)=óculos misfire, (0,2)=ROUPA real(4),
      # (1,0)=bag FORA da máscara, (1,1)=fundo, (1,2)=rosto sem máscara
      labels = Nx.tensor([[16, 3, 4], [16, 0, 11]], type: :u8)
      # máscara-cabeça: (0,0)=cabelo, (0,1)=rosto, (0,2)=cabelo[mas é roupa], (1,1)=cabelo
      mask = Nx.tensor([[2, 11, 2], [0, 2, 0]], type: :u8)

      out = HeadFusion.into_labels(labels, mask)

      # bag/óculos SOB a máscara → reivindicados (2/11); ROUPA(4) preservada;
      # bag FORA da máscara preservada (16); fundo→cabelo(2); rosto livre inalterado
      assert Nx.to_flat_list(out) == [2, 11, 4, 16, 2, 11]
    end
  end

  describe "run/1 no vídeo" do
    test "é no-op (só-foto): devolve máscara zerada sem rodar inferência" do
      labels = Nx.tensor([[4, 4], [0, 0]], type: :u8)
      ctx = %LayerContext{rgb: nil, labels: labels, video?: true}

      mask = HeadFusion.run(ctx)

      assert Nx.shape(mask) == {2, 2}
      assert Nx.sum(mask) |> Nx.to_number() == 0
    end
  end
end
