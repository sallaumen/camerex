defmodule Camerex.Neon.BackgroundTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Camerex.Neon.Background

  @h 12
  @w 12

  property "behind: op 0/nil é identidade; op>0 nunca escurece e é monótono" do
    check all(neon <- img(), original <- img()) do
      assert Background.behind(neon, original, 0.0) == neon
      assert Background.behind(neon, original, nil) == neon

      mid = Background.behind(neon, original, 0.3)
      high = Background.behind(neon, original, 0.7)

      assert ge?(mid, neon), "behind escureceu (op 0.3)"
      assert ge?(high, mid), "behind não é monótono (0.7 < 0.3)"
      assert Nx.shape(mid) == {@h, @w, 3}
    end
  end

  property "cutout: false é identidade; true dá RGBA com RGB intacto e alpha = máx" do
    check all(neon <- img()) do
      assert Background.cutout(neon, false) == neon

      rgba = Background.cutout(neon, true)
      assert Nx.shape(rgba) == {@h, @w, 4}
      assert eq?(rgba[[.., .., 0..2]], neon)
      assert eq?(rgba[[.., .., 3]], Nx.reduce_max(neon, axes: [2]))
    end
  end

  describe "behind/4 — desfoque do fundo revelado (bg_blur)" do
    test "bg_blur>0 desfoca o fundo (borda vaza); bg_blur=0 mantém nítido; neon segue cravado" do
      h = 8
      w = 16
      neon = Nx.broadcast(Nx.u8(0), {h, w, 3})
      # fundo com borda NÍTIDA na coluna 8: metade esquerda 0, direita 200
      left = Nx.broadcast(Nx.u8(0), {h, 8, 3})
      right = Nx.broadcast(Nx.u8(200), {h, 8, 3})
      original = Nx.concatenate([left, right], axis: 1)

      sharp = Background.behind(neon, original, 1.0, 0.0)
      blurred = Background.behind(neon, original, 1.0, 1.0)

      # sem blur a borda é nítida: coluna 7 (à esquerda) fica exatamente 0
      assert Nx.to_number(sharp[[0, 7, 0]]) == 0
      # com blur a borda vaza: coluna 7 pega valor do lado direito (> 0)
      assert Nx.to_number(blurred[[0, 7, 0]]) > 0
      # longe da borda o desfoque não inventa brilho (coluna 0 segue 0)
      assert Nx.to_number(blurred[[0, 0, 0]]) == 0
    end
  end

  defp img do
    gen all(bytes <- binary(length: @h * @w * 3)) do
      bytes |> Nx.from_binary(:u8, backend: Nx.BinaryBackend) |> Nx.reshape({@h, @w, 3})
    end
  end

  defp ge?(a, b), do: a |> Nx.greater_equal(b) |> Nx.all() |> Nx.to_number() == 1
  defp eq?(a, b), do: a |> Nx.equal(b) |> Nx.all() |> Nx.to_number() == 1
end
