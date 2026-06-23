defmodule Camerex.Parser.Texture do
  @moduledoc """
  Textura local (desvio-padrão da luminância em janela). Cabelo é fio-sobre-fio
  (alta textura), pele lisa (baixa) — separa cabelo de pele da mesma cor.
  Extraído de `Hair`/`Skin` onde estava duplicado.
  """

  @tex_window 7

  @doc "Limiar de textura escalado por sensibilidade 0..1 (default 0.5 = 9)."
  @spec tex_thr(number() | nil) :: integer()
  def tex_thr(s) when is_number(s), do: round(13 - clamp01(s) * 8)
  def tex_thr(_), do: tex_thr(0.5)

  @spec to_gray(Nx.Tensor.t()) :: Nx.Tensor.t()
  def to_gray(rgb) do
    rgb
    |> Evision.Mat.from_nx_2d()
    |> Evision.cvtColor(Evision.Constant.cv_COLOR_RGB2GRAY())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.as_type(:f32)
  end

  @spec box_blur(Nx.Tensor.t()) :: Nx.Tensor.t()
  def box_blur(nxf) do
    nxf
    |> Evision.Mat.from_nx_2d()
    |> Evision.blur({@tex_window, @tex_window})
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  @doc "Desvio-padrão local: sqrt(E[x²] − E[x]²) em janela `@tex_window`."
  @spec local_std(Nx.Tensor.t()) :: Nx.Tensor.t()
  def local_std(rgb) do
    gray = to_gray(rgb)
    mean = box_blur(gray)

    box_blur(Nx.multiply(gray, gray))
    |> Nx.subtract(Nx.multiply(mean, mean))
    |> Nx.max(0.0)
    |> Nx.sqrt()
  end

  defp clamp01(s) when is_number(s), do: s |> max(0.0) |> min(1.0)
end
