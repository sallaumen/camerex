defmodule Camerex.CalibrationTest do
  # depende do :segmenter/:parser Fixture global configurado em config/test.exs
  use ExUnit.Case, async: false

  alias Camerex.Calibration

  defp scene(h, w), do: Nx.broadcast(Nx.u8(127), {h, w, 3})

  defp params(overrides \\ %{}) do
    Map.merge(%{"halo" => 0.6, "detail" => 0.5}, overrides)
  end

  test "prepare reduz para largura 480 preservando proporção e segmenta" do
    assert {:ok, %{rgb: rgb, mask: mask}} = Calibration.prepare(scene(750, 1000))
    assert Nx.shape(rgb) == {360, 480, 3}
    assert Nx.shape(mask) == {360, 480}
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
end
