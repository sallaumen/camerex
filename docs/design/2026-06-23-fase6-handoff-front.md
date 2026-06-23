# Handoff Fase 6 (UI data-driven) — o backend já expõe tudo

> Backend de camadas modulares ENTREGUE e pushado (Fases 0-5). Falta a UI
> data-driven. Spec detalhado: `2026-06-23-camerex-camadas-modulares-design.md`
> (seção "Fase 6"). Este doc é o atalho: o que o backend EXPÕE hoje (código
> real, não mais hipótese) e o que falta plugar no front.

## O que o backend já dá pronto pra UI

**`Camerex.Parser.LayerRegistry`** (catálogo, compile-time):
- `ui_specs/0` → lista de mapas (LayerSpec SEM `:module` — seguro pros assigns,
  não vaza captures). Cada um: `%{id, label, class, group, fg_spec, color_mode,
  gate, params, sampleable?, order_band}`.
- `all/0`, `active/1` (lê `params["detect_<bool>"]`), `param_keys/0`.
- `fetch/1` aceita **atom OU string** e faz `Enum.find` — **seguro contra atom
  exhaustion**. Use SEMPRE isto pra mapear o id vindo do cliente (NUNCA
  `String.to_atom`).

**`Camerex.Parser.LayerSpec.param_key(spec, kind)`** → a chave do param por kind
(`:bool|:color|:slider|:model`). Ex.: pra saber qual o toggle/slider/cor de uma
camada sem hard-coded.

**`Camerex.RenderParams`** já tem TODOS os campos de camada (detect_*, *_color,
*_model, *_sensitivity) — derivados do catálogo. `from_form`/`from_manifest`/
`to_manifest` tratam por kind. `hair_model` (kind `:model`) faz round-trip do
mapa e é PRESERVADO no `from_form` (vem do eyedropper/região, não do `<form>`).

**`Camerex.Calibration.learn_hair_model(session, {x0,y0,x1,y1})`** → modelo de
cor por REGIÃO arrastada (devolve `%{mu, cov_inv, cx, cy, sigma}` | nil). É o
caminho robusto pro cabelo (clique→modelo foi refutado no pixel real).

## Referência: o toggle de pele JÁ feito (padrão a generalizar)

`convert_panel.ex` tem o bloco de pele (toggle `detect_skin` + slider
`skin_sensitivity`, sem color picker — `color_mode: :auto`). É um dos 4 blocos
copy-paste (object/aerial/hair/skin) que a Fase 6 substitui por um `:for`.

## O que falta (Fase 6 completa)

1. **`convert_panel`**: trocar os 4 blocos colados por
   `<.layer_section :for={spec <- @ui_layer_specs} …>` lendo `ui_specs/0`. Cada
   `spec.params` diz quais inputs desenhar por kind; `spec.group != nil` →
   swatch; `spec.sampleable?` → botão de região. Camadas com `group: nil`
   (hair/skin) NÃO desenham swatch (a cor sai do grid base de `Layers`).
2. **Botão "+ adicionar camada"**: lista `ui_specs/0` menos as ativas; o item
   dispara `add_layer` com `phx-value-id`; o handler (`LayerRegistry.fetch(id)`)
   liga `detect_<id>`. `remove_layer` desliga.
3. **Conta-gotas/região genérico**: hoje `eyedrop_armed` é UM booleano e o
   handler grava SEMPRE em `hair_color`. Generalizar: `eyedrop_armed` vira
   `{layer, bool}`; evento `sample_region {layer, bbox}` despacha pra
   `mod.sample_region(rgb, bbox)` (só camadas `sampleable?`). Hook JS lê
   `data-layer` e emite o id. **Amostragem é por REGIÃO (bbox→modelo), não
   clique** (o clique único foi refutado).
4. **`Layers.groups/0`** passa a derivar de `LayerRegistry` (as entradas
   object/apparatus saem do catálogo; pele/cabelo/roupa continuam ATR fixas).
   Toca `suggest_colors`/`merge_form_colors`/`normalize_colors`.

## Invariantes a não quebrar (testados)

- Ordem do reduce = `order_band` (baseline→overlay→**destructive=Skin por
  último**). Não reordenar.
- `render_params_symmetry_test`: todo param do catálogo existe no struct E no
  manifest. Se adicionar/alterar param, esse teste guia.
- Prévia ao vivo NÃO roda U²-Net por slider (cache na `Calibration` session).
  Há teste que conta chamadas ao segmenter.
