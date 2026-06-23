defmodule Camerex.Parser.ColorModelTest do
  use ExUnit.Case, async: true
  alias Camerex.Parser.ColorModel

  test "to_lab(rgb u8) devolve tensor float {h,w,3}" do
    rgb = Nx.broadcast(Nx.u8(120), {4, 4, 3})
    lab = ColorModel.to_lab(rgb)
    assert Nx.shape(lab) == {4, 4, 3}
    assert Nx.type(lab) == {:f, 32}
  end

  test "mahalanobis: distância 0 no centro do cluster, com identidade como cov_inv" do
    lab = Nx.broadcast(Nx.tensor([50.0, 0.0, 0.0]), {3, 3, 3})
    mu = Nx.tensor([50.0, 0.0, 0.0])
    ci = Nx.eye(3) |> Nx.as_type(:f32)
    d2 = ColorModel.mahalanobis(lab, mu, ci)
    assert Nx.to_number(d2[1][1]) == 0.0
  end

  test "mahalanobis aceita mu/cov_inv como LISTAS (caminho do manifest)" do
    lab = Nx.broadcast(Nx.tensor([50.0, 0.0, 0.0]), {2, 2, 3})
    mu = [50.0, 0.0, 0.0]
    ci = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
    d2 = ColorModel.mahalanobis(lab, mu, ci)
    assert Nx.to_number(d2[0][0]) == 0.0
  end

  test "build_model devolve mapa serializável (mu[3] + cov_inv[9])" do
    lab = Nx.broadcast(Nx.tensor([50.0, 10.0, -5.0]), {3, 3, 3})
    w = Nx.broadcast(1.0, {3, 3})
    model = ColorModel.build_model(lab, w, 9)
    assert is_list(model.mu) and length(model.mu) == 3
    assert is_list(model.cov_inv) and length(model.cov_inv) == 9
  end
end
