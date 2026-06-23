defmodule Camerex.Segmenter.U2Net do
  @moduledoc """
  Pré/pós-processamento puro do U²-Net, fiel à rembg (contrato §4).
  Sem I/O e sem inferência: o adapter (`Camerex.Segmenter.Ortex`) injeta
  o modelo entre `preprocess/1` e `postprocess/2`.
  """

  # normalização ImageNet usada pela rembg
  @mean [0.485, 0.456, 0.406]
  @std [0.229, 0.224, 0.225]

  @doc """
  `{h, w, 3}` u8 RGB → `{1, 3, 320, 320}` f32: resize INTER_AREA →
  `t / max(reduce_max(t), 1.0e-6)` → `(t - mean) / std` por canal →
  HWC→CHW + eixo de batch.

  INTER_AREA no downscale: o resize por interpolação do OpenCV (LANCZOS4,
  LINEAR) não faz anti-aliasing e o aliasing desloca a predição do U²-Net
  (spike 0.7, scripts/spikes/RESULTS.md).
  """
  @spec preprocess(Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  def preprocess(rgb, opts \\ []) do
    size = Keyword.get(opts, :size, 320)
    mean = Keyword.get(opts, :mean, @mean)
    std = Keyword.get(opts, :std, @std)
    # normalização da escala: `:max` (divide pelo máximo, quirk da rembg/u2net) ou
    # um divisor fixo (ex.: 255.0 para o BiRefNet/transformers)
    norm = Keyword.get(opts, :norm, :max)

    t =
      rgb
      |> Evision.Mat.from_nx_2d()
      |> Evision.resize({size, size}, interpolation: Evision.Constant.cv_INTER_AREA())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)
      |> Nx.as_type(:f32)

    t =
      case norm do
        :max -> Nx.divide(t, Nx.max(Nx.reduce_max(t), 1.0e-6))
        div when is_number(div) -> Nx.divide(t, div)
      end

    t
    |> Nx.subtract(Nx.tensor(mean))
    |> Nx.divide(Nx.tensor(std))
    |> Nx.transpose(axes: [2, 0, 1])
    |> Nx.new_axis(0)
  end

  @doc """
  Output d0 `{1, 1, 320, 320}` f32 → min-max → ×255 u8 → resize LANCZOS4
  para `{h, w}`. Devolve alpha contínuo 0..255; o limiar fica em `binarize/1`.
  """
  @spec postprocess(Nx.Tensor.t(), {pos_integer(), pos_integer()}, keyword()) :: Nx.Tensor.t()
  def postprocess(d0, {h, w}, opts \\ []) do
    pred = d0[[0, 0]] |> activate(Keyword.get(opts, :activation, :minmax))

    pred
    |> Nx.multiply(255.0)
    |> Nx.as_type(:u8)
    |> Evision.Mat.from_nx()
    |> Evision.resize({w, h}, interpolation: Evision.Constant.cv_INTER_LANCZOS4())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  # u2net/isnet: o output é um mapa cru → normaliza min-max pra 0..1. BiRefNet: o
  # output é um LOGIT → sigmoid pra 0..1.
  defp activate(pred, :minmax) do
    mn = Nx.reduce_min(pred)
    mx = Nx.reduce_max(pred)
    pred |> Nx.subtract(mn) |> Nx.divide(Nx.max(Nx.subtract(mx, mn), 1.0e-6))
  end

  defp activate(pred, :sigmoid), do: Nx.divide(1.0, Nx.add(1.0, Nx.exp(Nx.negate(pred))))

  @doc "Alpha u8 0..255 → máscara binária u8 0|255 (limiar `alpha > 30`, contrato §4)."
  @spec binarize(Nx.Tensor.t()) :: Nx.Tensor.t()
  def binarize(alpha) do
    alpha |> Nx.greater(30) |> Nx.multiply(255) |> Nx.as_type(:u8)
  end
end
