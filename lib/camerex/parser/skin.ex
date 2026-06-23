defmodule Camerex.Parser.Skin do
  @moduledoc """
  Re-classifica a PELE NUA do torço/costas que o ATR rotula como ROUPA. O modelo
  ATR (SegFormer) não tem classe de "torso nu" — assume todo mundo vestido —
  então uma bailarina sem top tem a pele do tronco rotulada como vestido/upper
  (DRESS cobre ~8% na foto aérea real). Detector PURO que conserta isso SEM modelo
  extra (sinal = labels ATR + rgb; NÃO roda U²-Net):

    1. **Modelo de cor** aprendido AUTO dos pixels que o ATR JÁ acerta como pele
       (rosto/braços/pernas, classes 11-15): média + inversa da covariância no
       Lab. O cluster da pele dos membros é o mesmo do torço nu sob a mesma luz;
       a covariância (não um raio fixo) sobrevive à luz colorida.
    2. **Candidato** = pixel de ROUPA (4-8,17) com Mahalanobis baixo ao modelo.
    3. **Conectividade** (o discriminador FORTE): cresce a pele-ATR geodesicamente
       para dentro do candidato — só vira pele a roupa que TOCA pele real (o torço
       é contíguo aos braços). Cor sozinha vaza; ancorar no corpo real é o que
       segura, e é o que diferencia este módulo do Hair (que precisa de cor do
       usuário).
    4. **Piso de luminância** (a calça é mais ESCURA que a pele): L ≥ μ_L − k·σ_L.
    5. **Textura baixa** (pele lisa vs tecido dobrado), generoso.
    6. **Teto de área**: se re-rotularia roupa demais (colapso de cor), aborta.

  Re-rótulo é one-way: só ROUPA→PELE (classe 11), nunca toca membro/rosto/cabelo/
  fundo. Puro; OPT-IN (é destrutivo). Roda como ÚLTIMO augmentor, sobre os labels
  ATR originais.
  """

  alias Camerex.Parser.{ColorModel, MaskOps, Texture}

  @skin_ids [11, 12, 13, 14, 15]
  @clothing_ids [4, 5, 6, 7, 8, 17]
  @skin_class 11

  # SENSIBILIDADE (0..1, default 0.5) afrouxa/aperta cor + textura + piso-L juntos
  defp maha_thr(s), do: 6.0 + s * 8.0
  defp tex_max(s), do: round(10 + s * 12)
  defp l_floor_k(s), do: 1.5 + s * 1.5

  # piso de pele-ATR pra confiar (membros cobertos → não adivinhar)
  @min_skin_frac 0.005
  # teto: re-rotular mais que isto da ROUPA = colapso de cor → aborta (no-op)
  @max_reframe_frac 0.6
  # regularização da covariância do modelo de pele (skin_model é local; o
  # ColorModel global usa o seu próprio @cov_reg)
  @cov_reg 1.0
  @grow_div 50
  @grow_iters 40
  @consolidate_div 60

  @doc """
  Máscara u8 `{h, w}` (0|255) do torço/costas nu (pixels de ROUPA que são pele).
  Vazia se não há pele-ATR suficiente (membros cobertos) ou se re-rotularia roupa
  demais (trava anti-vazamento). `opts[:sensitivity]` 0..1 (default 0.5).
  """
  @spec detect(Nx.Tensor.t(), Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  def detect(labels, rgb, opts \\ []) do
    {h, w} = Nx.shape(labels)
    s = opts |> Keyword.get(:sensitivity, 0.5) |> clamp01()
    skin_ref = in_set(labels, @skin_ids)
    skin_px = skin_ref |> Nx.sum() |> Nx.to_number()

    if skin_px < @min_skin_frac * h * w do
      empty_u8(h, w)
    else
      torso = torso_skin(labels, rgb, skin_ref, skin_px, s, h, w)
      cap(torso, in_set(labels, @clothing_ids), h, w)
    end
  end

  @doc """
  Injeta a classe `11` (pele) onde HÁ torço-pele E o ATR rotulou ROUPA. One-way:
  nunca toca membro/rosto/cabelo/fundo. O grupo `:skin` (11-15) já compõe na mesma
  cor neon de pele, então não precisa de classe virtual nem mexer no `Layers`.
  """
  @spec into_labels(Nx.Tensor.t(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def into_labels(labels, skin_u8) do
    where = Nx.logical_and(Nx.greater(skin_u8, 0), in_set(labels, @clothing_ids))
    Nx.select(where, Nx.broadcast(Nx.u8(@skin_class), Nx.shape(labels)), labels)
  end

  # torço nu = roupa que casa a cor da pele (Mahalanobis + piso-L + textura baixa)
  # E está conectada à pele-ATR (crescimento geodésico)
  defp torso_skin(labels, rgb, skin_ref, skin_px, s, h, w) do
    clothing = in_set(labels, @clothing_ids)
    lab = ColorModel.to_lab(rgb)
    {mu, cov_inv, mu_l, sd_l} = skin_model(lab, skin_ref, skin_px, h, w)

    candidate =
      clothing
      |> Nx.logical_and(Nx.less(ColorModel.mahalanobis(lab, mu, cov_inv), maha_thr(s)))
      |> Nx.logical_and(Nx.greater_equal(l_channel(lab), mu_l - l_floor_k(s) * sd_l))
      |> Nx.logical_and(Nx.less(Texture.local_std(rgb), tex_max(s)))

    skin_ref
    |> MaskOps.reconstruct(Nx.logical_or(candidate, skin_ref), w,
      div: @grow_div,
      iters: @grow_iters
    )
    |> Nx.logical_and(clothing)
    |> MaskOps.close_b(MaskOps.ellipse(round(w / @consolidate_div)))
    |> MaskOps.fill_holes(h, w)
    |> Nx.logical_and(clothing)
  end

  # teto anti-vazamento: re-rotular > 60% da roupa = colapso de cor → no-op
  defp cap(torso, clothing, h, w) do
    clo = clothing |> Nx.sum() |> Nx.to_number() |> max(1)
    got = torso |> Nx.sum() |> Nx.to_number()
    if got > @max_reframe_frac * clo, do: empty_u8(h, w), else: to_u8(torso)
  end

  # modelo de cor da pele (Lab) ponderado pela máscara dos membros; devolve também
  # μ_L e σ_L do canal de luminância pro piso da calça
  defp skin_model(lab, skin_ref, wsum, h, w) do
    w3 = skin_ref |> Nx.as_type(:f32) |> Nx.new_axis(-1)
    mu = lab |> Nx.multiply(w3) |> Nx.sum(axes: [0, 1]) |> Nx.divide(wsum)
    ctr = Nx.subtract(lab, Nx.reshape(mu, {1, 1, 3}))
    fc = Nx.reshape(ctr, {h * w, 3})
    fw = ctr |> Nx.multiply(w3) |> Nx.reshape({h * w, 3})
    cov = fw |> Nx.transpose() |> Nx.dot(fc) |> Nx.divide(wsum)
    cov_inv = Nx.LinAlg.invert(Nx.add(cov, Nx.multiply(Nx.eye(3), @cov_reg)))
    mu_l = mu[0] |> Nx.to_number()
    sd_l = cov[[0, 0]] |> Nx.to_number() |> max(1.0) |> :math.sqrt()
    {mu, cov_inv, mu_l, sd_l}
  end

  defp l_channel(lab), do: lab |> Nx.slice_along_axis(0, 1, axis: -1) |> Nx.squeeze(axes: [-1])

  defp in_set(labels, ids) do
    Enum.reduce(ids, false_like(labels), fn id, acc ->
      Nx.logical_or(acc, Nx.equal(labels, id))
    end)
  end

  defp clamp01(s) when is_number(s), do: s |> max(0.0) |> min(1.0)
  defp clamp01(_), do: 0.5

  defp false_like(t), do: Nx.broadcast(Nx.tensor(false), Nx.shape(t))
  defp empty_u8(h, w), do: Nx.broadcast(Nx.u8(0), {h, w})
  defp to_u8(m), do: m |> Nx.multiply(255) |> Nx.as_type(:u8)
end
