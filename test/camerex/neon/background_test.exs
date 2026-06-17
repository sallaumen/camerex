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

  defp img do
    gen all(bytes <- binary(length: @h * @w * 3)) do
      bytes |> Nx.from_binary(:u8, backend: Nx.BinaryBackend) |> Nx.reshape({@h, @w, 3})
    end
  end

  defp ge?(a, b), do: a |> Nx.greater_equal(b) |> Nx.all() |> Nx.to_number() == 1
  defp eq?(a, b), do: a |> Nx.equal(b) |> Nx.all() |> Nx.to_number() == 1
end
