defmodule Camerex.Parser.SegformerTest do
  use ExUnit.Case, async: false

  alias Camerex.Parser.Segformer

  describe "fetch_model/1 (degradação graciosa)" do
    test "processo ausente vira {:error, :parser_unavailable} — não derruba o chamador" do
      # GenServer.call a um nome não-registrado LEVANTA exit; o adapter captura e
      # devolve o contrato {:error,_} pra a with-chain (ex.: HeadFusion/Calibration)
      # seguir, em vez de crashar a Task da prévia.
      assert {:error, {:parser_unavailable, _}} =
               Segformer.fetch_model(:segformer_inexistente_para_teste)
    end
  end

  describe "parse/1 (modelo real)" do
    # precisa do modelo real em priv/models — corre com `mix test --include model`
    setup do
      case Process.whereis(Segformer) do
        nil -> start_supervised!(Segformer)
        _pid -> :ok
      end

      :ok
    end

    @tag :model
    test "parse devolve labels {h,w} u8 com classes ATR plausíveis" do
      # campo cinza simples só exercita o caminho ponta-a-ponta do modelo
      rgb = Nx.broadcast(Nx.u8(120), {200, 160, 3})

      assert {:ok, labels} = Segformer.parse(rgb)
      assert Nx.shape(labels) == {200, 160}
      assert Nx.type(labels) == {:u, 8}
      assert labels |> Nx.reduce_max() |> Nx.to_number() <= 17
    end
  end
end
