defmodule Camerex.Parser.MaskOpsTest do
  use ExUnit.Case, async: true
  alias Camerex.Parser.MaskOps

  test "dilate_b cresce a máscara em 1px com kernel 3x3" do
    m = Nx.tensor([[0, 0, 0], [0, 1, 0], [0, 0, 0]], type: :u8) |> Nx.greater(0)
    out = MaskOps.dilate_b(m, MaskOps.ellipse(3))
    assert Nx.to_number(Nx.sum(Nx.as_type(out, :u8))) > 1
  end

  test "ellipse devolve struct Evision com tamanho mínimo 1" do
    assert %Evision.Mat{} = MaskOps.ellipse(0)
    assert %Evision.Mat{} = MaskOps.ellipse(7)
  end

  test "fill_holes preenche buraco circundado, mantém fundo aberto" do
    # quadrado 5x5 com furo no meio
    mask =
      Nx.broadcast(0, {7, 7})
      |> Nx.put_slice([1, 1], Nx.broadcast(1, {5, 5}))
      |> Nx.put_slice([3, 3], Nx.broadcast(0, {1, 1}))
      |> Nx.greater(0)

    out = MaskOps.fill_holes(mask, 7, 7)
    assert Nx.to_number(out[3][3]) == 1
    assert Nx.to_number(out[0][0]) == 0
  end

  test "reconstruct cresce SEED dentro de CONFINE até estabilizar" do
    # 9x9 com semente central; confine cobre tudo. Kernel default ~w/55 daria 0
    # (forçado a 1, no-op); passamos div: 3 (kernel 3x3) pra crescer de fato.
    seed =
      Nx.broadcast(0, {9, 9}) |> Nx.put_slice([4, 4], Nx.broadcast(1, {1, 1})) |> Nx.greater(0)

    confine = Nx.broadcast(1, {9, 9}) |> Nx.greater(0)
    out = MaskOps.reconstruct(seed, confine, 9, div: 3, iters: 3)
    assert Nx.to_number(Nx.sum(Nx.as_type(out, :u8))) > 1
  end
end
