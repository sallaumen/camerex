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

  test "preset desconhecido devolve erro" do
    {:ok, session} = Calibration.prepare(scene(32, 32))

    assert {:error, {:unknown_preset, "vaporwave"}} =
             Calibration.render(session, params(%{"preset" => "vaporwave"}))
  end
end
