defmodule Camerex.Segmenter.FixtureTest do
  use ExUnit.Case, async: false

  alias Camerex.Segmenter.Fixture

  @moduletag :tmp_dir

  test "sem config devolve retângulo central h/2 x w/2, binário u8" do
    rgb = Nx.broadcast(Nx.u8(127), {8, 8, 3})

    assert {:ok, mask} = Fixture.segment(rgb, [])
    assert Nx.shape(mask) == {8, 8}
    assert Nx.type(mask) == {:u, 8}

    # retângulo: linhas 2..5, colunas 2..5 (top = h/4, lado = h/2) → 16 px
    assert mask |> Nx.greater(0) |> Nx.sum() |> Nx.to_number() == 16
    assert Nx.to_number(mask[2][2]) == 255
    assert Nx.to_number(mask[5][5]) == 255
    assert Nx.to_number(mask[1][1]) == 0
    assert Nx.to_number(mask[6][6]) == 0
  end

  test "com :fixture_mask_path devolve o PNG redimensionado ao input",
       %{tmp_dir: tmp} do
    # PNG 4x4: metade esquerda 255, metade direita 0
    png = Path.join(tmp, "mask.png")

    half =
      Nx.tensor(
        [
          [255, 255, 0, 0],
          [255, 255, 0, 0],
          [255, 255, 0, 0],
          [255, 255, 0, 0]
        ],
        type: :u8
      )

    Evision.imwrite(png, Evision.Mat.from_nx(half))

    Application.put_env(:camerex, :fixture_mask_path, png)
    on_exit(fn -> Application.delete_env(:camerex, :fixture_mask_path) end)

    rgb = Nx.broadcast(Nx.u8(0), {8, 8, 3})
    assert {:ok, mask} = Fixture.segment(rgb, [])

    assert Nx.shape(mask) == {8, 8}
    # NEAREST mantém binário: colunas 0..3 = 255, 4..7 = 0
    assert Nx.to_number(mask[0][0]) == 255
    assert Nx.to_number(mask[7][3]) == 255
    assert Nx.to_number(mask[0][4]) == 0
    assert Nx.to_number(mask[7][7]) == 0

    uniq = mask |> Nx.to_flat_list() |> Enum.uniq() |> Enum.sort()
    assert uniq == [0, 255]
  end
end
