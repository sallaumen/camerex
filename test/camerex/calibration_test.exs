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

  test "prepare reduz para 480 preservando proporção, parseia e cacheia o mean-shift" do
    assert {:ok, session} = Calibration.prepare(scene(750, 1000))
    assert Nx.shape(session.rgb) == {360, 480, 3}
    # fg PREGUIÇOSO: prepare não segmenta (só quando a camada é ligada no render)
    assert session.fg_cache == %{}
    assert session.head_cache == nil
    # mean-shift (caro) pré-computado 1× aqui
    assert session.edges != nil
  end

  test "prepare preserva imagens que já cabem na prévia" do
    assert {:ok, %{rgb: rgb}} = Calibration.prepare(scene(64, 100))
    assert Nx.shape(rgb) == {64, 100, 3}
  end

  test "render devolve {data URL de PNG decodificável, sessão}" do
    {:ok, session} = Calibration.prepare(scene(64, 64))

    assert {:ok, "data:image/png;base64," <> b64, %{} = _session} =
             Calibration.render(session, params())

    assert <<137, "PNG", _rest::binary>> = Base.decode64!(b64)
  end

  test "halo muda a prévia renderizada" do
    {:ok, session} = Calibration.prepare(scene(64, 64))

    {:ok, fraco, _} = Calibration.render(session, params(%{"halo" => 0.1}))
    {:ok, forte, _} = Calibration.render(session, params(%{"halo" => 0.9}))

    assert fraco != forte
  end

  test "bloom muda a prévia renderizada" do
    {:ok, session} = Calibration.prepare(scene(64, 64))

    {:ok, sem, _} = Calibration.render(session, params())
    {:ok, com, _} = Calibration.render(session, params(%{"bloom" => 0.9}))

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
    {:ok, teal, _} = Calibration.render(session, base)

    {:ok, azul, _} =
      Calibration.render(session, put_in(base["layer_colors"], %{"clothing" => [0, 0, 255]}))

    assert teal != azul
  end

  test "chão ligado muda a prévia (e anexa o piso)" do
    {:ok, session} = Calibration.prepare(scene(64, 64))

    {:ok, sem, _} = Calibration.render(session, params())
    {:ok, com, _} = Calibration.render(session, params(%{"floor" => true}))

    assert sem != com
  end

  test "fg preguiçoso: segmenta 1× na 1ª render e REUSA a sessão devolvida nas seguintes" do
    prev = Application.get_env(:camerex, :segmenter)
    Application.put_env(:camerex, :segmenter, CountingSegmenter)
    start_supervised!(CountingSegmenter)
    on_exit(fn -> Application.put_env(:camerex, :segmenter, prev) end)

    {:ok, session} = Calibration.prepare(scene(64, 64))
    # prepare NÃO segmenta (fg preguiçoso)
    assert CountingSegmenter.count() == 0

    active = params(%{"detect_object" => true, "detect_aerial" => true})
    {:ok, _, session} = Calibration.render(session, active)
    after_first = CountingSegmenter.count()
    assert after_first > 0, "1ª render deveria segmentar as camadas ligadas"

    # renders seguintes REUSAM o fg_cache da sessão devolvida — não segmenta de novo
    {:ok, _, session} = Calibration.render(session, Map.put(active, "halo", 0.1))
    {:ok, _, _} = Calibration.render(session, Map.put(active, "halo", 0.9))

    assert CountingSegmenter.count() == after_first,
           "render re-segmentou (prévia ao vivo regrediria): #{CountingSegmenter.count()} > #{after_first}"
  end

  test "head_fusion: cacheia a máscara-cabeça na sessão (não re-infere por slider)" do
    {:ok, session} = Calibration.prepare(scene(64, 64))
    assert session.head_cache == nil

    hf = params(%{"detect_head_fusion" => true})
    {:ok, _, session} = Calibration.render(session, hf)
    # rodou as inferências 1× e guardou a máscara-cabeça
    assert session.head_cache != nil
    cached = session.head_cache

    # render seguinte reusa o MESMO cache (ensure_head só roda com head_cache nil)
    {:ok, _, session} = Calibration.render(session, Map.put(hf, "halo", 0.9))
    assert session.head_cache == cached
  end
end
