defmodule Camerex.Parser.PersonFill do
  @moduledoc """
  Preenche os BURACOS que o ATR (SegFormer) deixa em pose aérea/invertida: o
  parser foi treinado em fotos EM PÉ, então em pose suspensa joga pixels-de-pessoa
  no FUNDO (classe 0) e a pessoa "some" no neon. Esta camada usa uma silhueta
  robusta-a-pose (`isnet-general-use`, SOD class-agnostic via Ortex) pra re-rotular
  esses pixels como CORPO.

  Pipeline:
    1. **buraco** = silhueta_SOD ∩ (labels == 0) — pixels que o SOD vê como pessoa
       mas o ATR jogou no fundo.
    2. **abertura** (open) — remove o APARELHO/escada finos (o SOD pega o tecido/
       lira colado na pessoa) e o anel de descasamento entre os dois modelos; os
       buracos do CORPO (massa) sobrevivem.
    3. **conectividade** — cresce a pessoa-ATR geodesicamente pra dentro dos buracos
       abertos; só vira corpo o buraco COLADO na pessoa real (anti falso-positivo
       de fundo saliente).
    4. **re-rótulo por classe vizinha** (`into_labels`) — cada buraco herda a classe
       de corpo ATR mais próxima (distance transform por classe), pra o neon do
       buraco pegar a cor da parte adjacente (pele/roupa/cabelo) em vez de um blob
       de cor única.

  Puro (recebe a silhueta no ctx; quem roda o ONNX é o chamador). Roda PRIMEIRO
  (baseline), antes de object/tecido/cabelo/pele, pra eles operarem sobre os
  labels já preenchidos. Opt-in (dispara o isnet além do ATR).

  LIMITE: cena escura/baixo-contraste — o SOD também não acha a pessoa (depende de
  saliência visual), então o buraco persiste. Provado no corpus aéreo.
  """

  @behaviour Camerex.Parser.Layer

  alias Camerex.Parser.{LayerContext, MaskOps}

  # kernel da abertura (~8px em 512w): remove aparelho/escada finos + anel
  @open_div 60
  # crescimento geodésico da conectividade buraco↔pessoa
  @grow_div 28
  @grow_iters 35
  # componente FITA (aspect alt/larg ou larg/alt acima disto) = tecido/aparelho,
  # não corpo — descartado do preenchimento (mesma lição do Parser.Hair)
  @max_aspect 4.0
  # classes ATR de CORPO candidatas ao preenchimento (NÃO objeto 18 / tecido 19)
  @body_ids [2, 4, 5, 6, 7, 8, 11, 12, 13, 14, 15, 17]
  @skin_class 11

  @doc """
  Máscara u8 `{h, w}` (0|255) dos buracos-de-pessoa que o ATR perdeu pro fundo.
  Vazia se não há silhueta (`fg` nil) ou nenhum buraco colado na pessoa.
  """
  @impl Camerex.Parser.Layer
  @spec run(LayerContext.t()) :: Nx.Tensor.t()
  def run(%LayerContext{fg: nil, labels: labels}), do: empty(labels)

  def run(%LayerContext{fg: fg, labels: labels}) do
    {_h, w} = Nx.shape(labels)
    person = Nx.greater(labels, 0)
    holes = Nx.logical_and(Nx.greater(fg, 0), Nx.logical_not(person))
    opened = MaskOps.open_b(holes, MaskOps.ellipse(round(w / @open_div)))

    person
    |> MaskOps.reconstruct(Nx.logical_or(person, opened), w, div: @grow_div, iters: @grow_iters)
    |> Nx.logical_and(opened)
    |> drop_ribbons()
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
  end

  # descarta componentes FITA (tecido/aparelho vertical longo) — só fica a massa
  # de corpo. stats: [x, y, larg, alt, área].
  defp drop_ribbons(mask) do
    {n, lbls, stats, _c} = mask |> MaskOps.to_mat() |> Evision.connectedComponentsWithStats()

    if n <= 1 do
      mask
    else
      st = Evision.Mat.to_nx(stats, Nx.BinaryBackend)
      {bw, bh} = {st[[.., 2]], st[[.., 3]]}
      aspect = Nx.max(Nx.divide(bh, Nx.max(bw, 1)), Nx.divide(bw, Nx.max(bh, 1)))

      keep =
        aspect
        |> Nx.less(@max_aspect)
        |> Nx.as_type(:u8)
        |> Nx.put_slice([0], Nx.tensor([0], type: :u8))

      lbls_nx = lbls |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.as_type(:s64)
      keep |> Nx.take(lbls_nx) |> Nx.greater(0)
    end
  end

  @doc """
  Re-rotula os buracos pela classe de CORPO ATR mais próxima. One-way: só toca
  onde havia FUNDO (classe 0); nunca sobrescreve corpo/objeto/tecido já rotulados.
  """
  @impl Camerex.Parser.Layer
  @spec into_labels(Nx.Tensor.t(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def into_labels(labels, holes_u8) do
    where = Nx.logical_and(Nx.greater(holes_u8, 0), Nx.equal(labels, 0))
    Nx.select(where, nearest_body_class(labels), labels)
  end

  # classe de corpo ATR mais próxima de cada pixel (só as presentes na imagem)
  defp nearest_body_class(labels) do
    present = Enum.filter(@body_ids, fn c -> Nx.to_number(Nx.sum(Nx.equal(labels, c))) > 0 end)
    fill_from(present, labels)
  end

  # sem nenhuma classe de corpo (ATR achou só fundo) → assume pele
  defp fill_from([], labels), do: Nx.broadcast(Nx.u8(@skin_class), Nx.shape(labels))

  defp fill_from(classes, labels) do
    idx = classes |> Enum.map(&dist_to(labels, &1)) |> Nx.stack() |> Nx.argmin(axis: 0)
    Nx.take(Nx.tensor(classes, type: :u8), idx)
  end

  # distância (L2) de cada pixel ao pixel mais próximo da classe `c`
  defp dist_to(labels, c) do
    labels
    |> Nx.not_equal(c)
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
    |> Evision.Mat.from_nx()
    |> Evision.distanceTransform(Evision.Constant.cv_DIST_L2(), 3)
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  defp empty(labels), do: Nx.broadcast(Nx.u8(0), Nx.shape(labels))
end
