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
  """
  @spec behind(Nx.Tensor.t(), Nx.Tensor.t(), number() | nil) :: Nx.Tensor.t()
  def behind(neon, original, op) when is_number(op) and op > 0.0 do
    bg = original |> Nx.as_type(:f32) |> Nx.multiply(op)
    neon |> Nx.as_type(:f32) |> Nx.max(bg) |> Nx.clip(0, 255) |> Nx.as_type(:u8)
  end

  def behind(neon, _original, _op), do: neon

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
