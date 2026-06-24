defmodule Camerex.Parser.SchpTest do
  use ExUnit.Case, async: false

  alias Camerex.Parser.Schp

  describe "fetch_model/1 (degradação graciosa)" do
    test "processo ausente vira {:error, :parser_unavailable} — HeadFusion segue só com o ATR" do
      # o child Schp pode não estar vivo (ex.: servidor iniciado antes do child ser
      # adicionado à árvore). Sem a captura, o GenServer.call levantaria exit e
      # derrubaria a Task da prévia; com ela, o HeadFusion zera a contribuição do
      # SCHP e recupera a cabeça só com o ATR.
      assert {:error, {:parser_unavailable, _}} =
               Schp.fetch_model(:schp_inexistente_para_teste)
    end
  end

  describe "parse/1 (modelo real)" do
    # precisa do modelo real em priv/models — corre com `mix test --include model`
    setup do
      case Process.whereis(Schp) do
        nil -> start_supervised!(Schp)
        _pid -> :ok
      end

      :ok
    end

    @tag :model
    test "parse devolve labels {h,w} u8 com classes LIP plausíveis (≤19)" do
      rgb = Nx.broadcast(Nx.u8(120), {200, 160, 3})

      assert {:ok, labels} = Schp.parse(rgb)
      assert Nx.shape(labels) == {200, 160}
      assert Nx.type(labels) == {:u, 8}
      assert labels |> Nx.reduce_max() |> Nx.to_number() <= 19
    end
  end
end
