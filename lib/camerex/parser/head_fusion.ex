defmodule Camerex.Parser.HeadFusion do
  @moduledoc """
  Recupera a CABEÇA (cabelo + rosto) que o ATR perde em pose aérea/invertida,
  fundindo DOIS parsers de datasets diferentes em QUATRO orientações.

  O ATR (SegFormer) foi treinado em gente EM PÉ: na pose invertida ele zera o
  cabelo e fragmenta o corpo. Duas alavancas independentes, sem treinar nada:

    * **rotation-TTA** — roda o parser em 0/90/180/270; aos 180° a pose invertida
      cai no domínio em-pé do modelo. Desrotaciona o resultado.
    * **segunda opinião** — o SCHP (LIP, `Camerex.Parser.Schp`) lê a pose que o
      ATR não lê (provado: tecido-2 ATR 0px de cabelo, SCHP 4279px).

  Funde a UNIÃO das cabeças (cabelo ∪ rosto, dos dois parsers × 4 rotações),
  ANCORADA na "pessoa" = silhueta SOD (`ctx.fg`) ∪ foreground de cada parser. A
  âncora-união é o pulo do gato: na cena escura o SOD falha, mas o cabelo do SCHP
  fica ancorado no corpo que o PRÓPRIO SCHP achou (sem isso a tecido-2 caía de
  4279 pra 70px). Injeta cabelo(2)/rosto(11) só onde o ATR deixou FUNDO —
  conservador, não corrompe parse bom (pose em pé funde com ela mesma, no-op).

  CUSTO: 7 inferências extras (ATR ×3 + SCHP ×4; o ATR-0° reusa `ctx.labels`).
  Opt-in e **SÓ-FOTO** — no vídeo a camada é no-op (custo proibitivo por frame).
  Provado no pixel: cabelo recuperado nas 3 aéreas (1769/2336/1228px).
  """

  @behaviour Camerex.Parser.Layer

  alias Camerex.Parser
  alias Camerex.Parser.{LayerContext, Schp}

  # ATR (SegFormer ATR): cabelo 2, rosto 11. SCHP (LIP): cabelo 2, rosto 13.
  @hair_atr 2
  @face_atr 11
  @hair_lip 2
  @face_lip 13

  @impl Camerex.Parser.Layer
  @spec run(LayerContext.t()) :: Nx.Tensor.t()
  def run(%LayerContext{video?: true, labels: labels}), do: empty(labels)

  def run(%LayerContext{rgb: rgb, labels: labels, fg: fg}) do
    {h, w} = Nx.shape(labels)

    # ATR-0° reusa o parse-base (ctx.labels); ATR-90/180/270 e SCHP-0/90/180/270 inferem
    {atr_hair, atr_face, atr_fg} =
      head_union(&Parser.parse/1, @hair_atr, @face_atr, rgb, labels, {h, w})

    {schp_hair, schp_face, schp_fg} =
      head_union(&Schp.parse/1, @hair_lip, @face_lip, rgb, nil, {h, w})

    person =
      fg |> fg_mask({h, w}) |> Nx.logical_or(atr_fg) |> Nx.logical_or(schp_fg)

    combine(Nx.logical_or(atr_hair, schp_hair), Nx.logical_or(atr_face, schp_face), person)
  end

  @impl Camerex.Parser.Layer
  @spec into_labels(Nx.Tensor.t(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def into_labels(labels, mask) do
    # injeta a cabeça (mask ∈ {0,2,11}) só onde o ATR deixou FUNDO — não sobrescreve
    # roupa/membro já corretos (regressão zero em pose em pé)
    where = Nx.logical_and(Nx.greater(mask, 0), Nx.equal(labels, 0))
    Nx.select(where, mask, labels)
  end

  # --- fusão pura (tensor entra, tensor sai) --------------------------------

  @doc false
  # cabelo manda sobre rosto na sobreposição; ambos confinados à âncora "pessoa".
  # Devolve a máscara-cabeça u8 {h,w} com valores {0, 2 (cabelo), 11 (rosto)}.
  @spec combine(Nx.Tensor.t(), Nx.Tensor.t(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def combine(hair_union, face_union, person) do
    hair = Nx.logical_and(hair_union, person)
    face = face_union |> Nx.logical_and(person) |> Nx.logical_and(Nx.logical_not(hair))

    hair
    |> Nx.select(@hair_atr, Nx.select(face, @face_atr, 0))
    |> Nx.as_type(:u8)
  end

  # --- inferência rotacionada (impuro: roda os modelos) ---------------------

  # união (cabelo, rosto, foreground) de um parser sobre as 4 rotações,
  # desrotacionada. `base0` evita re-parsear o 0° (reusa ctx.labels do ATR).
  defp head_union(parse_fn, hid, fid, rgb, base0, {h, w}) do
    zero = Nx.broadcast(Nx.u8(0), {h, w})

    Enum.reduce(rotations(), {zero, zero, zero}, fn {code, inv}, {ha, fa, fg} ->
      labels =
        if code == nil and base0 != nil, do: base0, else: parse_at(parse_fn, rgb, code, inv)

      {Nx.logical_or(ha, Nx.equal(labels, hid)), Nx.logical_or(fa, Nx.equal(labels, fid)),
       Nx.logical_or(fg, Nx.greater(labels, 0))}
    end)
  end

  # parseia o rgb rotacionado e desrotaciona o label de volta ao frame original.
  # Falha de inferência → zeros (a orientação não contribui, sem derrubar a fusão).
  defp parse_at(parse_fn, rgb, code, inv) do
    rotated = rot(rgb, code)
    {rh, rw, _} = Nx.shape(rotated)

    labels =
      case parse_fn.(rotated) do
        {:ok, l} -> l
        _ -> Nx.broadcast(Nx.u8(0), {rh, rw})
      end

    rot(labels, inv)
  end

  # rotações lossless 0/90/180/270 (código, inverso) — OpenCV é exato em múltiplos de 90°
  defp rotations do
    cw = Evision.Constant.cv_ROTATE_90_CLOCKWISE()
    ccw = Evision.Constant.cv_ROTATE_90_COUNTERCLOCKWISE()
    r180 = Evision.Constant.cv_ROTATE_180()
    [{nil, nil}, {cw, ccw}, {r180, r180}, {ccw, cw}]
  end

  defp rot(t, nil), do: t

  defp rot(t, code) do
    t |> Evision.Mat.from_nx_2d() |> Evision.rotate(code) |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  defp fg_mask(nil, {h, w}), do: Nx.broadcast(Nx.u8(0), {h, w})
  defp fg_mask(fg, _hw), do: Nx.greater(fg, 0)

  defp empty(labels), do: Nx.broadcast(Nx.u8(0), Nx.shape(labels))
end
