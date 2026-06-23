defmodule Camerex.Parser.TextureTest do
  use ExUnit.Case, async: true
  alias Camerex.Parser.Texture

  test "local_std: região lisa = ~0; região com listras = > 0" do
    smooth = Nx.broadcast(Nx.u8(120), {32, 32, 3})
    rows = Nx.iota({32, 32}, axis: 0)
    stripes_2d = rows |> Nx.remainder(2) |> Nx.multiply(80) |> Nx.add(40) |> Nx.as_type(:u8)
    striped = stripes_2d |> Nx.new_axis(-1) |> Nx.broadcast({32, 32, 3})

    assert Nx.to_number(Nx.mean(Texture.local_std(smooth))) < 1.0
    assert Nx.to_number(Nx.mean(Texture.local_std(striped))) > 5.0
  end

  test "tex_thr é monotônico decrescente em s (sensibilidade maior = limiar menor)" do
    assert Texture.tex_thr(0.0) >= Texture.tex_thr(0.5)
    assert Texture.tex_thr(0.5) >= Texture.tex_thr(1.0)
  end

  test "tex_thr aceita valor não-numérico (cai pro default 0.5)" do
    assert Texture.tex_thr(nil) == Texture.tex_thr(0.5)
  end
end
