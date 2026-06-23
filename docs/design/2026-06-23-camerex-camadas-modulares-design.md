# Camadas modulares no camerex — behaviour + catálogo de dados

> Status: design aprovado em brainstorming (2026-06-23). Substitui o crescimento
> de `detect_*` à mão por uma fonte única declarativa. Próximo passo: plano de
> implementação via `writing-plans`.

## Por que

Hoje, adicionar **uma** camada de detecção (ex.: tecido aéreo, cabelo, torço nu)
toca **~9 arquivos / 13–16 pontos de edição** em 4 anéis (detector novo + 3
pipelines + 6 lugares de params + UI copy-paste). A consequência foi um **bug
latente confirmado no código atual**:

- `detect_skin` / `skin_sensitivity` estão em `@param_keys` e são lidos por
  `render_opts`/`frame_opts`/`maybe_skin`, mas **faltam no `RenderParams`**
  (`@booleans` / `@sliders` / `defstruct` / `@type`). Como `panel_params_for/2`
  monta params **só** a partir de `to_manifest/1`, a camada de pele está
  backend-completa porém **inalcançável pela UI hoje**.
- `hair_model` tem o mesmo furo: é lido por `render_opts` (`photo.ex:229`) mas
  **nunca emitido por `to_manifest/1`**. O modelo de cor aprendido por região
  não sobrevive ao reprocesso via formulário.

Essas duas dessincronias são consequência direta de **6 fontes-da-verdade
mantidas à mão** para a mesma lista de chaves. O objetivo do refactor é colapsar
essas 6 fontes em **1 catálogo declarativo** consumido pelos 3 pipelines, pelo
`RenderParams` e pela UI — e introduzir o botão **"+ adicionar camada"** sobre
esse catálogo, fechando o crescimento ad-hoc.

## O que entra e o que NÃO entra

**Entra (Fases 0–6, entrega única):**
- Extração dos helpers compartilhados (`MaskOps`, `ColorModel`, `Texture`),
  hoje duplicados byte-a-byte entre `Hair` e `Skin`.
- `@behaviour Camerex.Parser.Layer` com 2 callbacks obrigatórios checados pelo
  compilador (`run/1`, `into_labels/2`) + behaviour separado `Layer.Sampleable`
  para o conta-gotas/learn (só Hair implementa hoje).
- `%LayerSpec{}` declarativo + `Camerex.Parser.LayerRegistry` com a lista
  **ordenada** das camadas; ordem é semântica (Skin destrutivo por último),
  travada por invariante testado.
- Os 3 orquestradores (photo/video/calibration) viram **um `Enum.reduce` sobre
  o registry**; cache de U²-Net por `{model, kind}`.
- `RenderParams` + `@param_keys` da `Library` **derivam** do catálogo (codecs
  por kind `:bool`/`:slider`/`:color`/`:model`). Aqui o bug morre na raiz.
- UI data-driven: convert_panel itera o catálogo; botão **"+ adicionar camada"**
  lista o catálogo menos as ativas; conta-gotas/região vira genérico
  parametrizado pela camada.
- Camada **Pele do torço nu** entra no catálogo com `color_mode: :auto` (auto
  pelos membros, sem conta-gotas), confirmando que o sistema modela camadas
  sem pista de cor.

**Não entra (deliberado, YAGNI):**
- Protocolo Elixir (`defprotocol`) — avaliado e descartado: precisa de
  struct-marcador vazio, não enumera implementações, não desacopla params.
- Conta-gotas opcional de **pele** indicada pelo usuário — o sistema deixa o
  gancho aberto (a camada Skin pode passar a declarar `color_mode: :optional`
  no futuro sem refactor); só não construímos UI sem caso real que justifique.
- Mudança em `Camerex.Parser.ATR` / SegFormer.
- Mudança no contrato do `Layers.@groups` para classes ATR — só **deriva** dele.

## Princípios do desenho

Vindos do `elixir-thinking` e do painel adversarial (9 críticas sobre 3 designs):

1. **Camada é DADO + BEHAVIOUR**, nunca processo. Zero GenServer, zero
   Agent — os detectores continuam puros sobre tensores Nx/Evision.
2. **Polimorfismo de módulo via `@behaviour`** (não Protocol). O conjunto de
   camadas é fechado e nosso; o caso canônico de behaviour.
3. **Fonte única derivada**: o catálogo é a única lista; tudo (params,
   pipelines, UI) **deriva**, não duplica.
4. **Compile-time sempre que possível**: registry é uma lista literal num
   módulo, sem `String.to_atom` de input do usuário (atom exhaustion).
5. **Migração incremental sobre 324 testes verdes**, gate entre fases.

## Arquitetura

### Camadas conceituais

```
        ┌─ catálogo ─────────────────────────────────┐
        │  Camerex.Parser.LayerRegistry              │
        │  @layers [%LayerSpec{...}, ...]  (ordem)  │
        └──┬──────────┬──────────────────────────┬──┘
           │          │                          │
   ┌───────▼───┐  ┌───▼─────────────┐  ┌────────▼──────────┐
   │  Pipelines│  │  RenderParams +  │  │  UI (LiveView)    │
   │  (3): 1   │  │  @param_keys     │  │  convert_panel +  │
   │  reduce   │  │  derivam codecs  │  │  "+ adicionar     │
   │  cada     │  │  por kind        │  │  camada" + sample │
   └───────────┘  └──────────────────┘  └───────────────────┘
```

Cada caixa de baixo lê do registry; o registry **não conhece** ninguém de
baixo.

### `Camerex.Parser.Layer` (behaviour mínimo)

```elixir
defmodule Camerex.Parser.Layer do
  @callback run(Camerex.Parser.LayerContext.t()) :: Nx.Tensor.t()
  @callback into_labels(labels :: Nx.Tensor.t(), mask :: Nx.Tensor.t()) ::
              Nx.Tensor.t()
end
```

Por que `run/1` e não `detect/1`: as funções públicas atuais (`Hair.detect/5`,
`Skin.detect/3`, etc.) continuam existindo no módulo para os spikes/scripts e
testes diretos não quebrarem. `run/1` é o adaptador uniforme que o orquestrador
chama — internamente delega à `detect/...` (puro).

### `Camerex.Parser.Layer.Sampleable` (behaviour opcional, só Hair hoje)

```elixir
defmodule Camerex.Parser.Layer.Sampleable do
  @callback sample_region(rgb :: Nx.Tensor.t(),
                          bbox :: {number, number, number, number}) ::
              map() | nil
end
```

**Por região (bbox), não clique único**: a memória do projeto registra que o
clique→modelo foi **refutado no pixel real** (foto-3: vazou 28k px cobrindo
tronco+braço; ancorado colapsou pra 0). O arraste-de-região é a resposta
robusta e já está provado (8951 px limpos). O conta-gotas de clique único
(`Hair.sample_color/3`) continua existindo como atalho rápido, **fora** do
behaviour modular — é uma conveniência da camada Hair, não parte do contrato.

### `Camerex.Parser.LayerContext` (struct normalizado)

```elixir
defmodule Camerex.Parser.LayerContext do
  defstruct [:rgb, :labels, :fg, :color, :sensitivity, :video?, :spatial?]
end
```

- `rgb` — imagem RGB u8 (sempre presente).
- `labels` — labels correntes (atualizado a cada `into_labels` no reduce —
  acumulador).
- `fg` — tensor U²-Net pré-resolvido **por camada** segundo seu `fg_spec`
  (`nil` se camada não consome).
- `color` — `{r,g,b}` | `%{mu, cov_inv, …}` | `nil`. Resolvido pelo
  orquestrador a partir de `params[hair_color]` / `params[hair_model]` /
  `params[aerial_color]` segundo o spec da camada (regra:
  `model || color || nil` quando ambos existem; Hair tem essa precedência).
- `sensitivity` — float 0..1; default do spec se a camada tiver.
- `video?` / `spatial?` — flags simples; só Hair lê `spatial?` (no vídeo passa
  `false` porque o cabelo se move).

Camadas magras (Object) ignoram campos que não usam — Nx/Evision passa refs,
não cópias, então o custo é zero.

### `%LayerSpec{}` (catálogo)

```elixir
defmodule Camerex.Parser.LayerSpec do
  defstruct [
    :id,            # :object, :hair, :apparatus, :skin
    :module,        # Camerex.Parser.Object, …
    :label,         # "Objeto na mão"
    :class,         # 18 / 2 / 19 / 11
    :group,         # %{key, label, ids, default} ou nil (reusa grupo ATR)
    :fg_spec,       # %{model: "u2net", kind: :largest} | %{model: "u2netp", kind: :full} | :none
    :color_mode,    # :required | :optional | :auto | :none
    :gate,          # :always | :run_when_atr_blind  (Hair = blind)
    :params,        # [%{key, kind: :bool|:slider|:color|:model, default, ui_hint}]
    :sampleable?,   # true sse implementa Layer.Sampleable
    :order_band     # :baseline | :overlay | :destructive  (Skin = destructive)
  ]
end
```

**Os 4 enums acima existem porque a crítica adversarial mostrou que
booleanos colapsam semânticas distintas**:

- `color_mode`:
  - `:required` (Hair) — nil ⇒ orquestrador pula o detect (não roda U²-Net à toa).
  - `:optional` (Apparatus) — nil ⇒ detect roda só com saliência.
  - `:auto` (Skin) — não tem param `:color`; deriva dentro do detect.
  - `:none` (Object) — não usa cor.
- `fg_spec` = `%{model, kind}`, **não** átomo único. `model` (u2net vs u2netp)
  é ortogonal a `kind` (largest vs full). O cache `{model, kind}` reusa o
  segmenter 1× por par distinto (resolve o double-pass u2net atual em photo).
- `gate` enumera (não captura função) — só Hair tem `:run_when_atr_blind`
  (roda se `Hair.present?(labels) == false`). O `:gate` consome `labels`, não
  o ctx — invariante explícito.
- `order_band` traduz a dependência semântica das `into_labels`:
  - `:baseline` (Object/Apparatus) — escrevem só onde `labels==0`.
  - `:overlay` (Hair) — `@overwritable` (fundo + roupas).
  - `:destructive` (Skin) — re-rotula roupa→pele.
  O registry **ordena por `order_band`** (baseline → overlay → destructive) e
  um teste garante que rodar fora dessa ordem muda o resultado (refutação ativa).

### `Camerex.Parser.LayerRegistry`

```elixir
defmodule Camerex.Parser.LayerRegistry do
  @layers [
    %LayerSpec{id: :object,    module: Camerex.Parser.Object,    …},
    %LayerSpec{id: :apparatus, module: Camerex.Parser.Apparatus, …},
    %LayerSpec{id: :hair,      module: Camerex.Parser.Hair,      …},
    %LayerSpec{id: :skin,      module: Camerex.Parser.Skin,      …}
  ]

  def all, do: @layers
  def active(params), do: Enum.filter(@layers, &active?(&1, params))
  def fetch(id) when is_atom(id), do: Enum.find(@layers, &(&1.id == id))
  def fetch(id) when is_binary(id), do: Enum.find(@layers, &(to_string(&1.id) == id))
  def required_segmentations(active), do: …  # MapSet de {model, kind}
  def ui_specs, do: Enum.map(@layers, &to_ui/1)  # projeção SEM module/captures
end
```

`active?/2` consulta `params["detect_<id>"]`. `fetch/1` faz `Enum.find` (não
`String.to_atom`) — segurança contra atom exhaustion.

## Fluxo de dados

### Pipeline genérico (mesmo nos 3 orquestradores)

```elixir
def augment(labels, rgb, params, opts) do
  active = LayerRegistry.active(params)
  fg_cache = build_fg_cache(rgb, active, opts)  # rode 1× por {model, kind}

  Enum.reduce(active, labels, fn spec, acc ->
    if should_run?(spec, acc, params) do
      ctx = build_context(spec, acc, rgb, fg_cache, params)
      mask = spec.module.run(ctx)
      spec.module.into_labels(acc, mask)
    else
      acc
    end
  end)
end
```

`build_fg_cache` muda por orquestrador:
- **photo/video**: rodam `segmenter.segment/2` 1× por `{model, kind}` distinto
  exigido pelas camadas ativas (deduplica o double-pass u2net atual).
- **calibration**: lê do `session` pré-computado. `prepare/2` passa a **derivar**
  as segmentações de `LayerRegistry.required_segmentations(@layers)` (não mais
  hardcoded "u2net + u2netp"). Uma camada futura que pedir um terceiro par
  não toca `prepare/2`.

`should_run?` aplica `gate` (`:run_when_atr_blind` para Hair) e o degrade de
`color_mode: :required` (cor nil ⇒ pula).

### Persistência (codecs por kind)

`RenderParams` ganha helpers genéricos:

```elixir
@codecs %{
  bool:   {fn s -> s == "true" end,           &(&1 == true),            & &1},
  slider: {&parse_float/1,                    &parse_float/1,           & &1},
  color:  {&hex_to_rgb/1,                     &list_to_rgb/1,           &Tuple.to_list/1},
  model:  {fn _ -> :preserve end,             &keep_model/1,            & &1}
}
```

`from_form/2`, `from_manifest/2`, `to_manifest/1` iteram
`LayerRegistry.all() |> Enum.flat_map(& &1.params)` e aplicam o codec do
`kind`. `defstruct` permanece literal (necessário em compile-time) mas é
**conferido por teste de paridade** contra o catálogo — se você adicionar
um param ao spec e esquecer no struct, o teste falha.

`Library.@param_keys` deixa de ser lista textual:

```elixir
def param_keys, do: Enum.map(catalog_params(), & &1.key)
```

**Teste de simetria obrigatório** (a rede de segurança que falta hoje):

```elixir
test "catálogo, struct e manifest concordam em TODAS as chaves" do
  spec_keys = LayerRegistry.param_keys() |> MapSet.new()
  struct_keys = RenderParams.default() |> Map.from_struct() |> Map.keys() |> MapSet.new()
  manifest_keys = RenderParams.default() |> RenderParams.to_manifest() |> Map.keys() |> MapSet.new()
  assert MapSet.subset?(spec_keys, struct_keys)
  assert MapSet.equal?(spec_keys, manifest_keys)
end
```

Esse teste, sozinho, impede o próximo bug-Skin.

### UI data-driven

**Convert panel:**

```heex
<.layer_section :for={spec <- @ui_layer_specs}
                spec={spec}
                params={@render_params}
                eyedrop_armed={@eyedrop_armed} />
```

`<.layer_section>` renderiza o toggle obrigatório + slider (se tiver) +
swatch (se `spec.group != nil`) + conta-gotas/região (se `spec.sampleable?`).
Os 4 blocos colados de hoje viram um `:for`.

**Botão "+ adicionar camada":**

```heex
<.add_layer_menu available={LayerRegistry.ui_specs() -- active_specs} />
```

Cada item dispara `phx-click="add_layer" phx-value-id={spec.id}`. O handler:

```elixir
def handle_event("add_layer", %{"id" => id}, socket) do
  case LayerRegistry.fetch(id) do  # Enum.find por to_string, SEM to_atom
    nil  -> {:noreply, socket}
    spec -> {:noreply, socket |> put_render_params([{:"detect_#{spec.id}", true}]) |> rerender()}
  end
end
```

**Conta-gotas / região genérico** (resolve o ponto que o spec original deixou
implícito):

- Hook JS lê `data-layer={spec.id}` do `<img>` da prévia.
- `pushEvent("sample_region", {layer, bbox})` (genérico, não `eyedrop_hair`).
- `eyedrop_armed` no socket vira `{layer :: atom | nil}` ao invés de boolean.
- Handler único:

```elixir
def handle_event("sample_region", %{"layer" => id, "bbox" => bbox}, socket) do
  with %LayerSpec{module: mod, sampleable?: true} = spec <- LayerRegistry.fetch(id),
       result when not is_nil(result) <- mod.sample_region(socket.assigns.calib.rgb, bbox) do
    {:noreply, socket
      |> put_render_params([{model_param_key(spec), result}])
      |> assign(:eyedrop_armed, nil)
      |> rerender()}
  end
end
```

Hoje só Hair implementa; o catálogo deixa trivial estender (`Apparatus` pode
ganhar amostragem de cor de tecido no futuro sem reescrever a UI).

## Plano em fases (gate verde entre cada)

Cada fase é commitável isoladamente e roda o gate completo (`mix format` →
`mix test` → `mix credo --strict` → `mix dialyzer`).

### Fase 0 — extração de helpers compartilhados (zero comportamento muda)

- `Camerex.Parser.MaskOps`: `to_mat`/`of_mat`/`dilate_b`/`close_b`/`ellipse`/
  `reconstruct`/`fill_holes` (idênticos byte-a-byte em `hair.ex` e `skin.ex`).
- `Camerex.Parser.ColorModel`: `to_lab`/`mahalanobis`/`build_model` (reconcilia
  a divergência cov_inv-flat vs cov_inv-tensor — escolher tensor para uso
  interno + serializador `to_flat_list` para hair_model).
- `Camerex.Parser.Texture`: `to_gray`/`box_blur`/`local_std`/`tex_thr/1`.
- `Hair` e `Skin` passam a chamar os helpers. Suas funções públicas
  (`detect/...`, `into_labels/2`, `present?/1`, `learn_model/2`,
  `sample_color/3`) **não mudam de assinatura**. Risco: zero.

**Critério de aceitação:** gate verde, módulos `Hair`/`Skin` encolhem ~40%,
nenhum teste muda.

### Fase 1 — behaviour, LayerSpec, LayerRegistry (sem consumir ainda)

- Define `Camerex.Parser.{Layer, Layer.Sampleable, LayerContext, LayerSpec,
  LayerRegistry}`.
- Cada detector ganha:
  - `@behaviour Camerex.Parser.Layer`
  - `def run(ctx), do: detect(<args extraídos do ctx>)` — adaptador trivial,
    delega à função antiga.
  - Hair ganha `@behaviour Camerex.Parser.Layer.Sampleable` +
    `def sample_region(rgb, bbox), do: learn_model(rgb, bbox)`.
- `LayerRegistry` lista os 4 specs com seus metadados.
- **Nenhum** orquestrador é tocado.

**Critério:** gate verde + testes novos do registry (`required_segmentations/1`
devolve o conjunto certo por combinação de ativas; `ui_specs/0` não vaza
captures).

### Fase 2 — migrar `photo.ex` para o reduce

- `augment_labels` vira `Camerex.Pipeline.LayerRunner.run/4`, chamado por
  photo. Implementa o `build_fg_cache` que roda `segmenter` 1× por
  `{model, kind}` (mata o double-pass u2net real do object+hair).
- `render_opts` permanece (lê de manifest), mas a parte de injetar nos opts
  do detect some — o reduce monta `LayerContext` de `params`.
- Adiciona teste que **assert ao número de chamadas** ao segmenter via Mox
  para object+hair ligados = 1 só passada.

**Critério:** gate verde, ganho mensurável no spike de uma foto com 2 camadas
de u2net.

### Fase 3 — migrar `video.ex` (mesmo reduce)

- `augment_frame_labels` chama `LayerRunner.run/4` por frame.
- `frame_opts` deriva defaults de `LayerRegistry` (some o `== true` / `|| 0.5`
  inline).
- `spatial?: false` é passado pelo `LayerRunner` quando contexto é vídeo.

**Critério:** gate verde, processamento de um vídeo curto produz frames
idênticos byte-a-byte aos do main pre-refactor (snapshot).

### Fase 4 — migrar `calibration.ex` (sessão + reduce)

- `prepare/2` deriva segmentações de `LayerRegistry.required_segmentations/1`.
- `session` muda `@type` para `%{rgb, labels, fg_cache: %{{model, kind} => Nx.Tensor.t()}}`.
- `render_neon` chama `LayerRunner.run/4` lendo `fg` do cache.

**Critério:** prévia ao vivo continua respondendo em ms (não roda U²-Net por
slider — risco crítico que o review levantou). Validar com a foto-3 carregada
na LiveView.

### Fase 5 — `RenderParams` deriva do catálogo (CONSERTA O BUG)

- `from_form/2`, `from_manifest/2`, `to_manifest/1` iteram `param_specs()` e
  aplicam codec por kind (`:bool`, `:slider`, `:color`, `:model`).
- `defstruct` permanece literal mas ganha campos para Skin
  (`detect_skin: false, skin_sensitivity: 0.5`) e `hair_model` (`nil`) —
  guiado pelo **teste de simetria** que falha enquanto não baterem.
- `Library.param_keys/0` deriva do catálogo.
- Após esta fase: o toggle de pele **funciona** no manifest (sem mudança de
  UI ainda — o `convert_panel` ainda usa o bloco colado pré-refactor).

**Critério:** teste de simetria verde, manifest com `detect_skin: true`
sobrevive a `to_manifest |> from_manifest`, hair_model idem com round-trip
JSON dos floats (teste de propriedade).

### Fase 6 — UI data-driven + botão "+ adicionar camada"

- `convert_panel` substitui os 4 blocos por `<.layer_section :for={...}>`.
- Botão "+ adicionar camada" + `<.add_layer_menu>`.
- Hook JS lê `data-layer`, evento genérico `sample_region`.
- `eyedrop_armed` vira `{layer, bool}`; handler `sample_region` único.
- `Layers.@groups` passa a **derivar** de `LayerRegistry.catalog()`
  (`suggest_colors/2`, `merge_form_colors/2`, `normalize_colors/1`
  consultam o catálogo).
- Adiciona o spec da camada **Pele** ao catálogo com `color_mode: :auto`,
  `params: [%{key: :detect_skin, kind: :bool}, %{key: :skin_sensitivity, kind: :slider}]` —
  ela aparece sozinha no menu, sem conta-gotas, exatamente como deveria.

**Critério:** validar no browser (Claude Preview): adicionar/remover camada
funciona; toggle de pele aparece; conta-gotas/região do Hair migrou sem
regressão; reprocesso preserva params.

## Riscos identificados (do painel adversarial)

1. **`defstruct` não pode derivar de função em compile-time.** Mantemos
   `defstruct` literal e o teste de simetria pega esquecimentos. Sem macro.
2. **`prepare/2` da calibration é reescrita real, não trivial.** Reconhecido
   na Fase 4; foi por isso que não a coloquei como "primeira mais isolada".
3. **A previa ao vivo lê params por caminho diferente do reprocesso.** A
   Fase 4 unifica antes da Fase 5 mexer no `RenderParams` — ordem crítica.
4. **`String.to_atom` em handler de UI.** Sempre `Enum.find` por `to_string`
   contra a lista compile-time. Nunca `to_existing_atom` em input do form.
5. **Spikes em `scripts/spikes/*.exs` chamam `Hair.detect/5` direto.** Como
   mantemos as funções públicas antigas (e `run/1` é só adaptador), os spikes
   continuam funcionando — verificar antes de cada commit das Fases 2–4.

## Decisões resolvidas no brainstorming

- **Escopo**: tudo de uma vez (Fases 0–6). Plano único, fases commitáveis.
- **Cor da pele**: `:auto` agora (já validado: 29% no foto-3, 0% em pessoa
  vestida). O catálogo deixa o gancho aberto para um `color_mode: :optional`
  no futuro sem refactor — só não construímos UI sem caso real.
- **Protocol descartado**: anti-YAGNI, struct-marcador vazio, não enumera
  implementações.
- **Sampling por região**, não clique único (clique→modelo refutado no pixel
  real). `Hair.sample_color/3` continua existindo como atalho fora do
  behaviour.

## Próximo passo

`writing-plans` para transformar este spec em um plano de implementação
passo-a-passo com critérios de aceitação concretos por fase.
