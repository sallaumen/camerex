defmodule Camerex.Neon do
  @moduledoc """
  Núcleo puro do efeito neon: composição por MÁXIMO (Nx) da arte-de-linha com
  o campo de cor + halos borrados (Evision). Todos os tensores são RGB.
  """

  @doc """
  Composição por MÁXIMO (nunca soma): a arte-de-linha fica na cor exata do
  campo e os halos só preenchem ao redor. `input` é a linha (foto) ou o trail
  (vídeo), f32 `{h, w}` em [0, 1]; devolve RGB u8 `{h, w, 3}`.

  opts: `halo:` 0..1 (default 0.6) · `bloom:` 0..1 (default 0.0; brilho
  atmosférico sigma ~22, neutro em 0) · `color_field:` campo `{h, w, 3}` f32
  da cor-por-parte (obrigatório) · `current_edges:` nil | f32 `{h, w}` (vídeo).
  """
  @spec compose(Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  def compose(input, opts \\ []) do
    halo = Keyword.get(opts, :halo, 0.6)
    bloom = Keyword.get(opts, :bloom, 0.0)
    current_edges = Keyword.get(opts, :current_edges) || input

    w_big = min(0.92 * halo, 1.0)
    w_mid = min(1.33 * halo, 1.0)
    w_atmo = min(0.6 * bloom, 1.0)

    halo_big = input |> gaussian_blur(8.0) |> Nx.multiply(w_big)
    halo_mid = input |> gaussian_blur(3.0) |> Nx.multiply(w_mid)
    halo_atmo = input |> gaussian_blur(22.0) |> Nx.multiply(w_atmo)

    intens =
      halo_big |> Nx.max(halo_mid) |> Nx.max(halo_atmo) |> Nx.max(current_edges)

    Keyword.fetch!(opts, :color_field)
    |> Nx.multiply(Nx.new_axis(intens, -1))
    |> Nx.clip(0, 255)
    |> Nx.as_type(:u8)
  end

  defp gaussian_blur(t, sigma) do
    t
    |> Evision.Mat.from_nx()
    |> Evision.gaussianBlur({0, 0}, sigma)
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end
end
