defmodule Camerex.Parser.ColorModel do
  @moduledoc """
  Cor em Lab + Mahalanobis + aprendizado de modelo (média + cov_inv ponderada).
  Extraído de `Hair`/`Skin` onde estava duplicado. `cov_inv` é tensor `{3, 3}`
  internamente; `build_model/3` serializa pra listas (JSON-safe pro manifest).
  """

  @cov_reg 1.0

  @spec to_lab(Nx.Tensor.t()) :: Nx.Tensor.t()
  def to_lab(rgb) do
    rgb
    |> Evision.Mat.from_nx_2d()
    |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2Lab())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.as_type(:f32)
  end

  @doc "Lab da cor-alvo {r,g,b} em escala u8 (não float) — casa a escala da imagem."
  @spec lab_of({0..255, 0..255, 0..255}) :: Nx.Tensor.t()
  def lab_of({r, g, b}) do
    Nx.tensor([r, g, b], type: :u8)
    |> Nx.reshape({1, 1, 3})
    |> Evision.Mat.from_nx_2d()
    |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2Lab())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.as_type(:f32)
    |> Nx.reshape({3})
  end

  @doc """
  Distância de Mahalanobis² no Lab. Aceita `mu` e `ci` como listas (vindas do
  manifest) ou como tensores (uso interno).
  """
  @spec mahalanobis(Nx.Tensor.t(), Nx.Tensor.t() | [number()], Nx.Tensor.t() | [number()]) ::
          Nx.Tensor.t()
  def mahalanobis(lab, mu, ci) do
    mu_t = to_vec3(mu) |> Nx.reshape({1, 1, 3})
    ci_t = to_mat33(ci)
    diff = Nx.subtract(lab, mu_t)
    Nx.sum(Nx.multiply(Nx.dot(diff, ci_t), diff), axes: [-1])
  end

  @doc "Distância euclidiana no Lab (escala u8) até a cor-alvo (tensor {3})."
  @spec color_dist(Nx.Tensor.t(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def color_dist(lab, target) do
    lab
    |> Nx.subtract(Nx.reshape(target, {1, 1, 3}))
    |> Nx.pow(2)
    |> Nx.sum(axes: [-1])
    |> Nx.sqrt()
  end

  @doc """
  Média e inversa da covariância (Lab) ponderadas por `weight`. Devolve mapa com
  `mu` e `cov_inv` como LISTAS (serializável JSON pro manifest).
  """
  @spec build_model(Nx.Tensor.t(), Nx.Tensor.t(), number()) ::
          %{mu: [float()], cov_inv: [float()]}
  def build_model(lab, weight, wsum) do
    {bh, bw, _} = Nx.shape(lab)
    w3 = Nx.new_axis(weight, -1)
    mu = lab |> Nx.multiply(w3) |> Nx.sum(axes: [0, 1]) |> Nx.divide(wsum)
    ctr = Nx.subtract(lab, Nx.reshape(mu, {1, 1, 3}))
    fc = Nx.reshape(ctr, {bh * bw, 3})
    fw = ctr |> Nx.multiply(w3) |> Nx.reshape({bh * bw, 3})
    cov = fw |> Nx.transpose() |> Nx.dot(fc) |> Nx.divide(wsum)
    cov_inv = Nx.LinAlg.invert(Nx.add(cov, Nx.multiply(Nx.eye(3), @cov_reg)))
    %{mu: Nx.to_flat_list(mu), cov_inv: Nx.to_flat_list(cov_inv)}
  end

  defp to_vec3(%Nx.Tensor{} = t), do: t |> Nx.as_type(:f32) |> Nx.reshape({3})
  defp to_vec3(list) when is_list(list), do: Nx.tensor(list, type: :f32) |> Nx.reshape({3})

  defp to_mat33(%Nx.Tensor{} = t), do: t |> Nx.as_type(:f32) |> Nx.reshape({3, 3})
  defp to_mat33(list) when is_list(list), do: Nx.tensor(list, type: :f32) |> Nx.reshape({3, 3})
end
