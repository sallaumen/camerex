defmodule Camerex.Parser.SegformerTest do
  # precisa do modelo real em priv/models — corre com `mix test --include model`
  use ExUnit.Case, async: false

  @moduletag :model

  alias Camerex.Parser.Segformer

  setup do
    case Process.whereis(Segformer) do
      nil -> start_supervised!(Segformer)
      _pid -> :ok
    end

    :ok
  end

  test "parse devolve labels {h,w} u8 com classes ATR plausíveis" do
    # campo cinza simples só exercita o caminho ponta-a-ponta do modelo
    rgb = Nx.broadcast(Nx.u8(120), {200, 160, 3})

    assert {:ok, labels} = Segformer.parse(rgb)
    assert Nx.shape(labels) == {200, 160}
    assert Nx.type(labels) == {:u, 8}
    assert labels |> Nx.reduce_max() |> Nx.to_number() <= 17
  end
end
