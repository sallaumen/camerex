defmodule Camerex.Pipeline.PhotoFgCacheTest do
  @moduledoc """
  Rede de segurança do refactor de camadas: confirma que o cache do
  `fg_provider` faz o segmenter rodar 1× por `{model, kind}` distinto, mesmo
  com várias camadas pedindo a MESMA combinação (Object e Hair ambos pedem
  `{"u2net", :largest}` → uma passada só).

  Pré-refactor `photo.ex` chamava `segment(rgb, "u2net")` duas vezes — uma em
  `with_object`, outra em `with_hair`. Este teste falha se voltar a esse estado.
  """
  use ExUnit.Case, async: false

  alias Camerex.Pipeline.Photo

  defmodule CountingSegmenter do
    @behaviour Camerex.Segmenter

    use Agent
    alias Camerex.Segmenter.Fixture

    def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def calls, do: Agent.get(__MODULE__, & &1)

    @impl Camerex.Segmenter
    def segment(rgb, opts) do
      model = Keyword.get(opts, :model, "u2net")
      Agent.update(__MODULE__, &Map.update(&1, model, 1, fn n -> n + 1 end))
      Fixture.segment(rgb, opts)
    end
  end

  setup do
    prev = Application.get_env(:camerex, :segmenter)
    Application.put_env(:camerex, :segmenter, CountingSegmenter)
    start_supervised!(CountingSegmenter)
    on_exit(fn -> Application.put_env(:camerex, :segmenter, prev) end)
    :ok
  end

  test "object+hair ligados rodam u2net UMA vez só (cache fg compartilhado)" do
    rgb = Nx.broadcast(Nx.u8(120), {64, 64, 3})

    {:ok, _neon} =
      Photo.render_layered(rgb,
        detect_object: true,
        detect_hair: true,
        hair_color: {60, 45, 40}
      )

    calls = CountingSegmenter.calls()
    assert Map.get(calls, "u2net", 0) == 1, "esperava 1 chamada u2net, veio #{inspect(calls)}"
  end

  test "object + apparatus = 1× u2net (object) + 1× u2netp (apparatus), modelos diferentes" do
    rgb = Nx.broadcast(Nx.u8(120), {64, 64, 3})

    {:ok, _neon} =
      Photo.render_layered(rgb,
        detect_object: true,
        detect_aerial: true,
        aerial_color: {220, 30, 40}
      )

    calls = CountingSegmenter.calls()
    assert Map.get(calls, "u2net", 0) == 1
    assert Map.get(calls, "u2netp", 0) == 1
  end

  test "nenhuma camada com fg → ZERO chamadas ao segmenter" do
    rgb = Nx.broadcast(Nx.u8(120), {64, 64, 3})

    {:ok, _neon} = Photo.render_layered(rgb, detect_skin: true)

    assert CountingSegmenter.calls() == %{}
  end
end
