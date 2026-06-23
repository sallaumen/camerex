defmodule Camerex.CalibrationTest do
  # depende do :segmenter/:parser Fixture global configurado em config/test.exs
  use ExUnit.Case, async: false

  alias Camerex.Calibration

  defmodule CountingSegmenter do
    @behaviour Camerex.Segmenter
    use Agent
    alias Camerex.Segmenter.Fixture

    def start_link(_), do: Agent.start_link(fn -> 0 end, name: __MODULE__)
    def count, do: Agent.get(__MODULE__, & &1)

    @impl Camerex.Segmenter
    def segment(rgb, opts) do
      Agent.update(__MODULE__, &(&1 + 1))
      Fixture.segment(rgb, opts)
    end
  end

  defp scene(h, w), do: Nx.broadcast(Nx.u8(127), {h, w, 3})

  defp params(overrides \\ %{}) do
    Map.merge(%{"halo" => 0.6, "detail" => 0.5}, overrides)
  end

  test "prepare reduz para largura 480 preservando proporção e segmenta" do
    assert {:ok, %{rgb: rgb, fg_cache: fg_cache}} = Calibration.prepare(scene(750, 1000))
    assert Nx.shape(rgb) == {360, 480, 3}
    # cache pré-computado com {model, kind} de todas as camadas; mask u2net largest
    assert Nx.shape(fg_cache[{"u2net", :largest}]) == {360, 480}
    assert Map.has_key?(fg_cache, {"u2netp", :full})
  end

  test "prepare preserva imagens que já cabem na prévia" do
    assert {:ok, %{rgb: rgb}} = Calibration.prepare(scene(64, 100))
    assert Nx.shape(rgb) == {64, 100, 3}
  end

  test "render devolve data URL de PNG decodificável" do
    {:ok, session} = Calibration.prepare(scene(64, 64))

    assert {:ok, "data:image/png;base64," <> b64} = Calibration.render(session, params())
    assert <<137, "PNG", _rest::binary>> = Base.decode64!(b64)
  end

  test "halo muda a prévia renderizada" do
    {:ok, session} = Calibration.prepare(scene(64, 64))

    {:ok, fraco} = Calibration.render(session, params(%{"halo" => 0.1}))
    {:ok, forte} = Calibration.render(session, params(%{"halo" => 0.9}))

    assert fraco != forte
  end

  test "bloom muda a prévia renderizada" do
    {:ok, session} = Calibration.prepare(scene(64, 64))

    {:ok, sem} = Calibration.render(session, params())
    {:ok, com} = Calibration.render(session, params(%{"bloom" => 0.9}))

    assert sem != com
  end

  test "trocar a cor de uma camada muda a prévia" do
    # cena com uma borda interna (quadrado claro) — uniforme não geraria bordas
    rows = Nx.iota({64, 64}, axis: 0)
    cols = Nx.iota({64, 64}, axis: 1)

    sq =
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, 18), Nx.less(rows, 48)),
        Nx.logical_and(Nx.greater_equal(cols, 18), Nx.less(cols, 48))
      )

    featured =
      Nx.select(
        Nx.new_axis(sq, -1) |> Nx.broadcast({64, 64, 3}),
        Nx.broadcast(Nx.u8(220), {64, 64, 3}),
        Nx.broadcast(Nx.u8(80), {64, 64, 3})
      )

    {:ok, session} = Calibration.prepare(featured)
    assert session.labels != nil

    base = params(%{"layer_colors" => %{"clothing" => [43, 196, 178]}})
    {:ok, teal} = Calibration.render(session, base)

    {:ok, azul} =
      Calibration.render(session, put_in(base["layer_colors"], %{"clothing" => [0, 0, 255]}))

    assert teal != azul
  end

  test "chão ligado muda a prévia (e anexa o piso)" do
    {:ok, session} = Calibration.prepare(scene(64, 64))

    {:ok, sem} = Calibration.render(session, params())
    {:ok, com} = Calibration.render(session, params(%{"floor" => true}))

    assert sem != com
  end

  test "render NÃO roda U²-Net por ajuste — a prévia ao vivo reusa o fg_cache" do
    prev = Application.get_env(:camerex, :segmenter)
    Application.put_env(:camerex, :segmenter, CountingSegmenter)
    start_supervised!(CountingSegmenter)
    on_exit(fn -> Application.put_env(:camerex, :segmenter, prev) end)

    {:ok, session} = Calibration.prepare(scene(64, 64))
    after_prepare = CountingSegmenter.count()
    assert after_prepare > 0

    # múltiplos render com camadas que usam U²-Net ligadas — NÃO pode segmentar de novo
    for halo <- [0.1, 0.5, 0.9] do
      {:ok, _} =
        Calibration.render(
          session,
          params(%{"halo" => halo, "detect_object" => true, "detect_aerial" => true})
        )
    end

    assert CountingSegmenter.count() == after_prepare,
           "render rodou o segmenter (prévia ao vivo regrediria): #{CountingSegmenter.count()} > #{after_prepare}"
  end
end
