# Spec do front — toggle de PELE + UX da cor do cabelo

> Backend pronto e validado no pixel real (foto-3). Estas são as duas peças de
> UI pendentes. **Não mexer no backend** — só `RenderParams`, `convert_panel`,
> `library_live` e `app.js`.

---

## Parte A — toggle "Pele do torço nu" (`detect_skin`)

**O quê.** O ATR (SegFormer) não tem classe de "torso nu" — assume todo mundo
vestido. Numa bailarina sem top, a pele das costas/tronco é rotulada como
roupa e pintada com a cor de roupa. `Camerex.Parser.Skin` re-rotula essa pele
nua (roupa → pele) aprendendo a cor da pele dos membros que o ATR JÁ acerta.

**Backend (pronto, não mexer):**
- `Camerex.Parser.Skin.detect/3` + `into_labels/2`.
- Fiado em `Photo`, `Video` e `Calibration` via os params `detect_skin`
  (bool, opt-in) e `skin_sensitivity` (0..1, default 0.5).
- `Library.@param_keys` já inclui `detect_skin` e `skin_sensitivity` (o
  reprocesso/persistência já carregam).
- Roda por ÚLTIMO (depois do aéreo) e **não dispara U²-Net** (sinal = labels
  ATR + rgb). Re-rótulo é one-way roupa→pele; nunca toca membro/rosto/cabelo.

**Front (fazer):**

1. `RenderParams` (`lib/camerex/render_params.ex`):
   - `@booleans` += `:detect_skin`; `@sliders` += `:skin_sensitivity`.
   - `defstruct` += `detect_skin: false, skin_sensitivity: 0.5` (e o `@type`).
   - `from_form/2`, `from_manifest/2`, `to_manifest/1` tratam ambos
     automaticamente só por estarem nas listas — **nada mais a fazer** (não é
     cor/tupla; é bool + slider, como `detect_aerial`/`aerial_sensitivity`).

2. `convert_panel` (`lib/camerex_web/components/convert_panel.ex`):
   - Um bloco espelhando o do tecido aéreo: um toggle "Pele do torço nu" ligado
     a `detect_skin` + um slider `skin_sensitivity` (0..1, step 0.05).
   - **Sem conta-gotas** — a pele aprende a própria cor dos membros sozinha.
   - Dica de UX: só faz diferença em pose sem top (costas/tronco à mostra);
     pra foto vestida normal o efeito é nulo (a trava de área aborta).

Nada na `library_live` além do que o `phx-change` do form já faz (o toggle e o
slider entram pelo `RenderParams.from_form/2`).

---

## Parte B — UX da cor do cabelo (o clique único é exigente)

### O problema (do usuário)
> "Como é só um clique, estou tendo que escolher várias vezes o pixel até
> encontrar um que dê certo."

O conta-gotas de clique único amostra **uma cor** (`hair_color`), que cai no
ramo de **limiar único apertado** do `Hair.detect`. Se o pixel clicado não for
representativo, a detecção falha — daí o "clicar várias vezes".

### O que NÃO fazer (testado e rejeitado no pixel real)
Tentei fazer o **mesmo clique virar um mini-modelo** (média + covariância da
vizinhança, alimentando o caminho Mahalanobis). **Falhou nas duas formas** no
foto-3 (luz vermelha funde cabelo louro e pele):
- **Sem âncora:** uma janela de clique na BORDA cabelo/pele infla a covariância
  → o elipsoide aceita pele → faz ponte cabeça→tronco num só componente
  (vazou 28k px cobrindo tronco+braço, vs 4,6k contidos da cor única).
- **Ancorado no pixel clicado:** aperta tanto que **não acende nada** (0 px no
  centro do cacho).

Não há ponto-ótimo: a covariância de UMA janela de clique é instável demais.
Quem mantém cabeça e tronco separados é justamente a cor mais apertada. **Não
reintroduzir o clique→modelo.**

### O que fazer — ARRASTE de região (robusto, backend pronto e provado)
A resposta certa pro "exigente" é deixar o usuário **marcar a região do cabelo**
(arrastar um retângulo na prévia). A região é curada pelo usuário (só tons de
cabelo) → variância legítima (perdoa qual tom) → e ganha um **prior espacial**
que contém o vazamento. Provado: foto-3 → **8951 px, 1 componente, limpo**.

**Backend (pronto, não mexer):**
- `Calibration.learn_hair_model(calib, {x0, y0, x1, y1})` (frações 0..1) →
  `%{mu, cov_inv, cx, cy, sigma}` ou `nil` (região sem textura de cabelo).
- `Hair.detect` já **prefere** o modelo: em `Calibration`,
  `params["hair_model"] || params["hair_color"]`. Modelo é JSON-safe (listas) e
  invariante à posição → serve foto E vídeo (segue o cacho frame a frame).
- `Library.@param_keys` já inclui `hair_model`.

**Front (fazer):**

1. `RenderParams`:
   - `defstruct` += `hair_model: nil` (e `@type` `hair_model: map() | nil`).
   - **Não** é slider/bool/tupla — tratar à mão:
     - `from_form/2`: **preserva** o atual (`hair_model: current.hair_model`) —
       o modelo NÃO vem do `<form>`, vem do evento de arraste.
     - `from_manifest/2`: `Map.put(:hair_model, p["hair_model"])` (mapa
       string-keyed ou nil; o `Hair` normaliza as duas formas).
     - `to_manifest/1`: `Map.put("hair_model", p.hair_model)`.

2. `library_live` (`lib/camerex_web/live/library_live.ex`):
   - Um modo "marcar cabelo" análogo ao `eyedrop_armed` (ex.: `region_armed`),
     com seu botão de armar/desarmar.
   - Handler novo (ex.: `"region_hair"`) recebendo `%{"x0","y0","x1","y1"}`
     (frações) do arraste → `Calibration.learn_hair_model(calib, bbox)`:
     - `%{} = model` → `put_render_params(hair_model: model)` + desarma +
       `rerender_calibration()` + flash "modelo do cabelo capturado".
     - `nil` → flash "arraste sobre o cabelo (precisa de textura)".
   - **Importante:** quando o usuário mexer no color-picker manual de
     `hair_color`, **zerar** `hair_model` (`put_render_params(hair_model: nil)`)
     — senão o modelo (que tem precedência) ignora a escolha manual.

3. `app.js`:
   - Um hook de **arraste** na prévia (mousedown → mousemove → mouseup) que
     calcula a bbox em frações 0..1 (como o hook de clique do conta-gotas já faz
     pro `eyedrop_hair`) e dá `pushEvent("region_hair", {x0,y0,x1,y1})` no
     mouseup. Idealmente desenha o retângulo enquanto arrasta (feedback).

4. UX: **manter o conta-gotas de clique** como atalho rápido; o arraste é a
   opção robusta pras poses difíceis (a "opção pra facilitar" que o usuário
   pediu). Ambos gravam a pista do cabelo; o arraste vence quando os dois existem.
