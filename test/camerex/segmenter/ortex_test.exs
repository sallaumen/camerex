defmodule Camerex.Segmenter.OrtexTest do
  use ExUnit.Case, async: false

  alias Camerex.Segmenter.Ortex, as: Segmenter

  @moduletag :model

  setup do
    # desde a Fase 3 o app supervisiona o Ortex; usar a instância viva e
    # resetar o cache lazy para o teste de load ser determinístico
    pid =
      Process.whereis(Camerex.Segmenter.Ortex) ||
        start_supervised!(Camerex.Segmenter.Ortex)

    :sys.replace_state(pid, fn state -> %{state | models: %{}} end)
    :ok
  end

  defp casal_rgb do
    "exemplos/entrada/casal.jpg"
    |> Path.expand()
    |> Evision.imread()
    |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  test "segmenta imagem real: máscara binária u8 do tamanho do input" do
    rgb = casal_rgb()
    {h, w, 3} = Nx.shape(rgb)

    assert {:ok, mask} = Segmenter.segment(rgb)
    assert Nx.shape(mask) == {h, w}
    assert Nx.type(mask) == {:u, 8}

    # binária: todo pixel é 0 ou 255
    only_binary =
      Nx.equal(mask, 0)
      |> Nx.logical_or(Nx.equal(mask, 255))
      |> Nx.all()
      |> Nx.to_number()

    assert only_binary == 1
  end

  test "carrega modelos lazy, um por id, e serializa chamadas concorrentes" do
    pid = Process.whereis(Camerex.Segmenter.Ortex)
    assert :sys.get_state(pid).models == %{}

    rgb = Nx.broadcast(Nx.u8(200), {16, 16, 3})

    tasks =
      for _ <- 1..2 do
        Task.async(fn -> Segmenter.segment(rgb, model: "u2netp") end)
      end

    assert [{:ok, m1}, {:ok, m2}] = Task.await_many(tasks, :infinity)
    # determinístico: a fila do GenServer serializa e o resultado é idêntico
    assert Nx.to_binary(m1) == Nx.to_binary(m2)

    # um único load, reusado nas duas chamadas
    assert Map.keys(:sys.get_state(pid).models) == ["u2netp"]
  end

  test "modelo desconhecido devolve erro sem tocar o GenServer" do
    rgb = Nx.broadcast(Nx.u8(127), {8, 8, 3})
    assert {:error, {:unknown_model, "nope"}} = Segmenter.segment(rgb, model: "nope")
  end
end
