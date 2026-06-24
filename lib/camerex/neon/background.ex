defmodule Camerex.Neon.Background do
  @moduledoc """
  Composição PURA do fundo do neon (Calc), compartilhada por foto e vídeo:

    * `behind/3` — o original atenuado ATRÁS do traço (por máximo).
    * `cutout/2` — o recorte ALPHA do conteúdo (fundo transparente).

  Antes vivia duplicada/privada em `Pipeline.Photo` (behind + cutout) e
  `Pipeline.Video` (behind). Vídeo H.264 não carrega alpha, então só usa
  `behind/3`. Tensor entra, tensor sai — sem opts/IO.
  """

  @doc """
  Compõe o original atenuado atrás do neon por MÁXIMO: `max(neon, original × op)`.
  O neon brilhante domina; o original só preenche onde o fundo era escuro (cena
  "fantasma" sob o traço). `op` ≤ 0 (ou `nil`) → no-op (fundo preto).

  `blur` ∈ 0..1 (default 0) DESFOCA só o fundo revelado (profundidade
  fotográfica): como o neon é o termo nítido do `max/2`, borrar o `original`
  empurra a cena de fundo (escada/parede/cordas) pra trás e o traço nítido
  (corda/figura) salta — sem mexer no neon. Ortogonal ao `op` (brilho).
  """
  @spec behind(Nx.Tensor.t(), Nx.Tensor.t(), number() | nil, number()) :: Nx.Tensor.t()
  def behind(neon, original, op, blur \\ 0.0)

  def behind(neon, original, op, blur) when is_number(op) and op > 0.0 do
    bg = original |> defocus(blur) |> Nx.as_type(:f32) |> Nx.multiply(op)
    neon |> Nx.as_type(:f32) |> Nx.max(bg) |> Nx.clip(0, 255) |> Nx.as_type(:u8)
  end

  def behind(neon, _original, _op, _blur), do: neon

  # desfoque gaussiano só do fundo; `blur` ≤ 0 → no-op (fundo nítido)
  defp defocus(original, blur) when is_number(blur) and blur > 0.0 do
    {_h, w, _} = Nx.shape(original)
    k = blur_kernel(w, blur)

    original
    |> Evision.Mat.from_nx_2d()
    |> Evision.gaussianBlur({k, k}, 0)
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  defp defocus(original, _blur), do: original

  # kernel gaussiano ÍMPAR (exigência do OpenCV) ∝ largura × força; piso 3 pra o
  # knob sempre fazer algo perceptível quando ligado.
  defp blur_kernel(w, blur) do
    k = max(round(w / 16 * min(blur, 1.0)), 3)
    if rem(k, 2) == 0, do: k + 1, else: k
  end

  @doc """
  Recorte ALPHA: anexa um 4º canal = brilho do conteúdo (máximo dos canais RGB),
  então o preto absoluto fica transparente e neon/original ficam opacos. `false`
  → no-op (segue RGB `{h, w, 3}`).
  """
  @spec cutout(Nx.Tensor.t(), boolean()) :: Nx.Tensor.t()
  def cutout(neon, true) do
    alpha = neon |> Nx.reduce_max(axes: [2]) |> Nx.new_axis(-1)
    Nx.concatenate([neon, alpha], axis: 2)
  end

  def cutout(neon, false), do: neon
end
