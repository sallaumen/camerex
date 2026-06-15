defmodule Camerex.CalibrationTest do
  # depende do :segmenter Fixture global configurado em config/test.exs
  use ExUnit.Case, async: false

  alias Camerex.Calibration

  defp scene(h, w), do: Nx.broadcast(Nx.u8(127), {h, w, 3})

  defp params(overrides \\ %{}) do
    Map.merge(
      %{"preset" => "forro-teal", "halo" => 0.6, "detail" => 0.5, "swap_sides" => false},
      overrides
    )
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

  test "halo muda o resultado; preset muda a cor" do
    {:ok, session} = Calibration.prepare(scene(64, 64))

    {:ok, halo_fraco} = Calibration.render(session, params(%{"halo" => 0.1}))
    {:ok, halo_forte} = Calibration.render(session, params(%{"halo" => 0.9}))
    {:ok, ouro} = Calibration.render(session, params(%{"preset" => "ouro"}))

    assert halo_fraco != halo_forte
    assert ouro != halo_fraco
  end

  test "bloom muda a prévia renderizada" do
    {:ok, session} = Calibration.prepare(scene(64, 64))

    {:ok, sem} = Calibration.render(session, params())
    {:ok, com} = Calibration.render(session, params(%{"bloom" => 0.9}))

    assert sem != com
  end

  test "chroma muda a prévia renderizada" do
    # cena com contraste de COR (quadrado saturado), não só cinza
    rows = Nx.iota({64, 64}, axis: 0)
    cols = Nx.iota({64, 64}, axis: 1)

    inside =
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, 20), Nx.less(rows, 44)),
        Nx.logical_and(Nx.greater_equal(cols, 20), Nx.less(cols, 44))
      )

    bg = Nx.tensor([81, 81, 81], type: :u8) |> Nx.broadcast({64, 64, 3})
    sq = Nx.tensor([200, 30, 30], type: :u8) |> Nx.broadcast({64, 64, 3})
    colored = Nx.select(Nx.new_axis(inside, -1) |> Nx.broadcast({64, 64, 3}), sq, bg)

    {:ok, session} = Calibration.prepare(colored)

    {:ok, sem} = Calibration.render(session, params())
    {:ok, com} = Calibration.render(session, params(%{"chroma" => 0.8}))

    assert sem != com
  end

  test "modo layered: trocar a cor de uma camada muda a prévia" do
    {:ok, session} = Calibration.prepare(scene(64, 64))
    assert session.labels != nil

    base = params(%{"layered" => true, "layer_colors" => %{"clothing" => [43, 196, 178]}})
    {:ok, teal} = Calibration.render(session, base)

    {:ok, azul} =
      Calibration.render(session, put_in(base["layer_colors"], %{"clothing" => [0, 0, 255]}))

    assert teal != azul
  end

  test "preset desconhecido devolve erro" do
    {:ok, session} = Calibration.prepare(scene(32, 32))

    assert {:error, {:unknown_preset, "vaporwave"}} =
             Calibration.render(session, params(%{"preset" => "vaporwave"}))
  end
end
