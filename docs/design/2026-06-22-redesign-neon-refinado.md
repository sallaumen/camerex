# Redesign "neon refinado" — design doc

Data: 2026-06-22 · Status: aprovado (direção + base 16px) · Direção escolhida: **B — neon refinado premium**

Documento de projeto prévio para elevar a UI/UX do camerex do nível "aluno de
faculdade" para nível de front-end sênior, **mantendo a identidade neon** (a alma
do produto: uma ferramenta de arte de contorno neon). Baseado em auditoria visual
(telas reais), auditoria de código por dimensão e pesquisa de referências premium
(Linear, Raycast, Vercel/Geist, DaVinci/Lightroom, Emil Kowalski/animations.dev).

---

## 1. Princípios (a régua de toda decisão)

1. **O chrome recua, a arte avança.** O verde-escuro é moldura de galeria; o único
   neon vibrante na tela é a obra do usuário + 1 CTA. Toda decisão de cor no chrome
   é subtrativa.
2. **Elevação por luz, não por sombra.** Em dark, "mais perto" = surface mais clara.
   Escada de superfícies por luminância + hairline 1px. Zero drop-shadow estrutural.
3. **Glow é assinatura escassa, não textura.** Brilho só onde se nomeia o porquê:
   CTA primário, foco/estado ativo, status "processando", e a arte. Multi-camada
   (núcleo nítido + bloom largo fraco), nunca halo chapado em tudo.
4. **Hierarquia vem de tipo, não de efeito.** 3 tons de texto + 3 pesos + escala
   nomeada + tracking negativo nos títulos. Sem caixa-alta como hierarquia.
5. **Sistema, não improviso.** Cor, tipo, espaço, raio, motion são tokens no
   `@theme`. Nenhum hex/box-shadow/raio solto nos componentes.
6. **Um sistema só.** Arrancar o daisyUI azul/roxo da raiz; comprometer com os
   tokens `cx-*`.
7. **Acessível por padrão (WCAG 2.2 AA).** Foco visível sólido, alvos ≥24px,
   `lang=pt-BR`, alt útil, foco preso no modal, estado nunca só por cor.
8. **Provar no app real.** Validar cor/contraste/responsivo no DOM computado, não em
   screenshot (regra pessoal do dono).

Não-objetivos: não adicionar funcionalidades novas; manter a marca toda-minúscula
("camerex_"); manter todo o comportamento atual (conversão, jobs, presets, import).

---

## 2. Diagnóstico consolidado (por que hoje parece amador)

| # | Causa-raiz | Evidência |
|---|---|---|
| D1 | **Dois sistemas de cor brigando.** daisyUI carrega 2 temas azul/roxo (oklch 252–292°) ainda ativos; o `<html>` recebe `data-theme` e pinta a raiz de azul-acinzentado. | `app.css:245-313`; `root.html.heex:18-27`; `getComputedStyle(html)` = `oklch(0.30 0.016 252)` |
| D2 | **Glow em tudo** (swatch, thumb, CTA, card hover, badge) → "tudo brilha" = amador. | `app.css:66,71,107,143,165`; `convert_panel.ex:292` |
| D3 | **1 só nível de surface** (bg vs surface = 1.09:1, invisível); cards dependem de sombra. | `app.css:15-16,225` |
| D4 | **Sem escala** de tipo/espaço/raio. Base 18px força a UI a viver em `text-sm/xs` (69 de 78 usos); `py-1.5` aparece 28×; raios `rounded`/0.5/0.75rem/pill misturados (40× `rounded` cru). | grep no `lib/camerex_web` |
| D5 | **Tokens duplicados** como hex literais ~20× + `rgb(43 196 178)` hardcoded 5×; dim antigo `#7fa293` diverge do token. | `app.css:46-111` |
| D6 | **Borda única** `#2a4a3c` (1.72:1) reprovada em WCAG 1.4.11 para inputs/controles. | cálculo de contraste |
| D7 | **Foco invisível**: anel claro sobre teal = 1.63:1; ~10 de ~40 botões têm foco. Sem disabled/loading apesar de ações assíncronas. | `app.css:148`; `detail_panel.ex` 0/5 |
| D8 | **Sem responsivo**: as 3 colunas só esmagam no mobile; modal estoura a viewport. | screenshot 375px |
| D9 | **Código morto e concentrado**: `core_components.ex` (button/input/table) nunca usado mas arrasta o daisyUI; `LibraryLive` com 1202 linhas mistura view + estado + domínio (hex/rgb, colors_json) + 3 modais inline. | grep `<.button>` = 0; `library_live.ex:506-862,1097-1157` |
| D10 | **Detalhes off-brand**: `lang="en"`; topbar de loading azul `#29d`; flash em `alert-info/error` azul daisyUI; perf é card flutuante `z-50` sobre o rail. | `root.html.heex:2`; `app.js:36`; `core_components.ex:71-77`; `library_components.ex:305` |

---

## 3. Design tokens (fonte única da verdade no `@theme`)

> Cor em OKLCH (passos perceptualmente uniformes) com hue verde 163 / teal 184 /
> laranja 45. Hex ao lado é referência. Contrastes calculados (alvo dark: texto ≥6:1,
> UI/gráfico ≥3:1).

### 3.1 Superfícies (escada de elevação por luz)
```
--color-cx-well:      #0c1612   /* poço do preview/thumb — nível mais baixo */
--color-cx-bg:        #101a15   /* oklch(20.5% .018 163) — canvas/galeria */
--color-cx-surface:   #1a2a22   /* oklch(26.8% .026 163) — cards/painéis (1.19:1 vs bg) */
--color-cx-elevated:  #25392f   /* oklch(32.5% .032 163) — modal/popover/dropdown */
```

### 3.2 Bordas (dois papéis)
```
--color-cx-hairline:  #2e493c   /* oklch(38% .040 163) — DECORATIVA: separa cards/seções */
--color-cx-border:    #547f6b   /* oklch(56% .058 163) — FUNCIONAL: input/switch/slider/foco — 3.32:1 vs surface, passa WCAG 1.4.11 */
```

### 3.3 Texto (3 níveis)
```
--color-cx-text:      #d3e5db   /* oklch(90.5% .022 163) — corpo, 11.6:1 */
--color-cx-text-dim:  #a1b7ac   /* oklch(76% .030 163) — secundário, 7.2:1 */
--color-cx-text-faint:#7c9287   /* oklch(64% .030 163) — caption/disabled, 4.6:1 (nunca corpo) */
```

### 3.4 Acentos + estados (racionados)
```
--color-cx-teal:      #2bc4b2   /* identidade mantida, 7.75:1 — CTA/foco/ativo/arte */
--color-cx-teal-strong:#1fae9e  /* hover/preenchido (não usar p/ texto pequeno) */
--color-cx-orange:    #ff8e59   /* oklch(76% .153 45) — acento quente, parcimônia */
--cx-teal-rgb:        43 196 178 /* canal p/ alpha de glow */
--color-cx-success:   var(--color-cx-teal)
--color-cx-warning:   #e8c34a   /* estado processando/atenção */
--color-cx-danger:    #f06a5e   /* UM vermelho único (substitui red-300/red-500/#ff5c5c) */
```
> Decisão: `interrupted` deixa de reusar o laranja da marca — vira um estado próprio
> (warning), para o laranja não ser acento e estado ao mesmo tempo.

### 3.5 Glow (assinatura, multi-camada — máx. 3 pontos por tela)
```
--cx-glow-signature: 0 0 2px rgb(var(--cx-teal-rgb)/.8), 0 0 8px rgb(var(--cx-teal-rgb)/.42), 0 0 22px rgb(var(--cx-teal-rgb)/.18)
--cx-glow-hover:     0 0 2px rgb(var(--cx-teal-rgb)/.9), 0 0 10px rgb(var(--cx-teal-rgb)/.55), 0 0 28px rgb(var(--cx-teal-rgb)/.3)
--cx-glow-focus:     0 0 0 2px var(--color-cx-teal)   /* anel SÓLIDO (conta p/ WCAG) — bloom é extra opcional */
--cx-glow-status:    0 0 6px rgb(232 195 74/.45), 0 0 16px rgb(232 195 74/.22)  /* processando */
```
Uso permitido: CTA primário, `:focus-visible`/`:active` de controle, swatch
selecionado, badge `processing`, e a arte. **Proibido** em repouso de swatch,
trilho/thumb de slider, card e botão secundário.

### 3.6 Raio
```
--radius-control: .375rem (6px)   /* input, slider, swatch, botão */
--radius-card:    .625rem (10px)  /* card, seção, painel */
--radius-lg:      1rem    (16px)  /* modal */
--radius-pill:    9999px          /* badge, chip, toggle, handle */
```

### 3.7 Espaçamento (base 16px, grade 4px)
`4 · 8 · 12 · 16 · 24 · 32 · 48`. Ritmo: 8px dentro de grupo, 16px entre grupos,
24px de padding em card de conteúdo. **Expurgar os `.5`** (`py-1.5` etc.) — com 16px
a grade fecha em inteiros.

### 3.8 Tipografia (base **16px** — remover `html{font-size:18px}`)
```
--text-display: 2rem/1.15/-0.02em/600      (32px)
--text-h1:      1.5rem/1.2/-0.015em/600    (24px)
--text-h2:      1.25rem/1.3/-0.01em/600    (20px)
--text-body:    1rem/1.5/0/400             (16px)
--text-sm:      .875rem/1.45/0/400-500     (14px)
--text-label:   .8125rem/1.4/+0.01em/500   (13px — vira o .cx-section-title)
--text-caption: .75rem/1.35/+0.02em/500    (12px)
```
Pesos com papel: **400** ler · **500** interagir (labels/botões/valores) · **600**
anunciar (títulos). Cortar `bold` solto. `tabular-nums` nos valores que mudam ao
arrastar slider.

### 3.9 Motion
```
--cx-dur-fast: 120ms   --cx-dur-base: 180ms   --cx-dur-slow: 220ms
--cx-ease-out:    cubic-bezier(.16,1,.3,1)   /* default: entradas, hover, press */
--cx-ease-in-out: cubic-bezier(.65,0,.35,1)  /* só A→B na tela (thumb do switch) */
```
- `:active{ transform: scale(.97) }` em **todos** os botões (piso .96).
- Barra de progresso: animar `transform: scaleX()` com `transform-origin:left`
  (`--cx-dur-slow`), nunca `width`.
- Modal: enter fade+scale .97→1 (180ms), exit 120ms (mais rápido).
- topbar de loading em teal (`#2bc4b2`), mantendo `show(300)`.
- `done`: 1 pop único (`scale 1→1.12→1`, 320ms), não em loop.
- Bloco `@media (prefers-reduced-motion: reduce)` obrigatório: mata translate/scale-up/
  shimmer/neon-pulse, preserva `opacity` e `:active`.

---

## 4. Kit de componentes — `CamerexWeb.UI`

Novo módulo de design system (primitivos públicos), separado de `LibraryComponents`
(feature) e dos painéis. Promover o kit privado do `convert_panel` (slider/switch/
swatch/section) para cá.

| Componente | Variantes / attrs | Estados obrigatórios |
|---|---|---|
| `button/1` | `variant: primary\|secondary\|ghost\|danger`, `size: sm\|md` | hover, focus-visible (anel sólido AA), active (scale .97), disabled, loading (`phx-disable-with`) |
| `input/1`, `select/1` | base `.cx-input` token-based | focus (border `cx-border`→teal + anel), disabled, erro |
| `card/1` | slot, `interactive?` | hover (sobe p/ `elevated` + borda teal, sem glow) |
| `badge/1` | `tone: neutral\|info\|success\|warning\|danger`, `label` | `processing` com glow+pulse (reduced-motion off) |
| `modal/1` | `id`, `title`, slot | overlay, foco preso, esc, click-away, restaura foco no trigger, enter/exit |
| `progress/1` | `value 0..100` ou `%{done,total,eta}` | `role=progressbar` + `aria-valuenow`, scaleX |
| `close_button/1` / `icon_button/1` | `label` (aria) | foco, hover, active — substitui as 2 versões divergentes |
| `media_frame/1` | slot (img/video) | moldura única `max-h-[72vh]` (hoje repetida 5×) |
| `slider/1` `switch/1` `swatch/1` `section/1` | promovidos do convert_panel | glow só em foco/ativo/selecionado |

Foco padrão global no `app.css`:
`:where(a,button,[role=button],input,select,textarea):focus-visible{ outline:2px solid var(--color-cx-teal); outline-offset:2px }` — e remover os `focus-visible:ring` ad-hoc.

Assinatura única do CTA premium: só `variant=primary` carrega `--cx-glow-signature`
(intensifica p/ `--cx-glow-hover` no hover). Secundário/ghost nunca brilham.

---

## 5. Redesign por superfície

1. **Shell (LibraryLive):** trocar o `flex min-h-screen` por grid de altura fixa
   `grid h-screen grid-cols-[16rem_minmax(0,1fr)_380px]`: **rail** (pastas/presets,
   scroll próprio) · **palco** (preview/galeria, fundo `well`) · **inspetor**
   (controles do convert OU ações do detail, scroll próprio). Header vira barra fixa
   no topo do palco. Cada coluna rola sozinha (acaba o scroll único que empilha tudo).
2. **Galeria/card:** card em `surface` + hairline; thumb num `well`; a arte neon é o
   único elemento vibrante; hover sobe p/ `elevated` + borda teal (sem glow). `badge`
   + chip de tipo unificados via `badge/1`. Alt útil (`"antes — #{arquivo}"`).
3. **Inspetor (convert_panel):** seções com ritmo único (24px entre, 12px dentro);
   sliders/switch/swatch do kit (glow só em foco/ativo); `tabular-nums` nos valores;
   1 CTA primário. Passar o struct `%RenderParams{}` inteiro (acaba o fan-out de 16
   attrs).
4. **Detalhe (detail_panel):** **slider de revelação antes/depois** (handle
   arrastável; lado-a-lado vira modo alternativo); ações via `button/1`; foco em 100%
   dos controles.
5. **Modais:** 1 componente `modal/1` (os 3 inline viram chamadas curtas) com foco
   preso, esc, restauração de foco, enter/exit.
6. **Perf → status bar:** faixa fina persistente na base (estilo VS Code/Resolve),
   `cpu/ram/beam` como micro-medidores inline; sai o card flutuante `z-50`.
7. **Flash:** reescrever com tokens `cx-*` (sem `alert-*` daisyUI).
8. **Empty states / doctor banner / poço com xadrez** de transparência quando
   `transparent_bg` ligado.
9. **Responsivo:** colapsar as 3 colunas (inspetor vira overlay/bottom-sheet no
   mobile; rail vira drawer); modal responsivo.

---

## 6. Acessibilidade (WCAG 2.2 AA — checklist)

- Foco visível sólido em 100% dos interativos (anel teal 2px, offset 2px, ≥3:1).
- Anel de foco do CTA/controle teal: `box-shadow 0 0 0 2px` sólido + glow opcional
  (blur não conta p/ WCAG).
- Alvos ≥24px: checkbox 16→24, thumb do slider 16→24, ✕ de preset com min 24px.
- `lang="pt-BR"`; `<html class="dark" style="color-scheme:dark">` fixo.
- Alt útil nas imagens antes/depois; imagens decorativas `aria-hidden`.
- Modal: foco preso + `aria-modal` + inert no fundo + restaura foco no trigger.
- Estado nunca só por cor: ícone/forma no badge crítico; texto de severidade no perf.
- `prefers-reduced-motion`: desliga pulso/shimmer/translate.
- Border funcional ≥3:1 (token `cx-border`).

---

## 7. Organização do código

- **Matar o daisyUI:** remover os 2 `@plugin daisyui-theme` e (se nenhuma classe
  daisyUI sobrar) o `@plugin daisyui`; remover `theme_toggle/1` + script de tema do
  `root.html.heex`; fixar dark no `<html>`. Validar `getComputedStyle(html)` sem hue
  252–292.
- **Podar `core_components.ex`:** manter só `icon/1`, `flash/1` e helpers; remover
  button/input/table/list/header mortos.
- **Quebrar `LibraryLive` (1202 linhas):** extrair lógica pura de cor (`hex_to_rgb`,
  `colors_to_json`, `parse_colors_json`, `build_layer_colors`, `json_color`) para
  `Camerex.Parser.Layers`/`Camerex.ColorJSON` (testável sem socket); modais e topbar
  → componentes; `jobs_summary`/`doctor` → contextos.
- **Estrutura de componentes:** `components/ui/` (design system) vs
  `components/library/` (feature).
- Mover `versioned_media_url` p/ `Camerex.Workspace` (tira regra de cache da camada
  de componente).
- Tokenizar: trocar todo hex/`rgb()`/raio solto por `var(--…)`; remover `.neon-*`
  órfãos.

---

## 8. Roadmap em fases (cada fase: gate verde + prova no app real + commit na main)

- **Fase 0 — Fundação:** tokens no `@theme` (§3); matar daisyUI (§7); base 16px;
  `lang=pt-BR`; flash tokenizado; limpar hex/órfãos. *Prova:* `getComputedStyle(html)`
  sem azul; sem regressão visual grosseira.
- **Fase 1 — Kit `CamerexWeb.UI`:** componentes da §4 com estados + foco AA. *Prova:*
  cada primitivo renderiza e os estados existem no DOM.
- **Fase 2 — Superfícies + estrutura:** shell 3 colunas, poço, status bar, reveal
  slider, modal único, responsivo, glow racionado, motion. *Prova:* desktop +
  mobile (375px) ok; glow só onde previsto.
- **Fase 3 — Organização:** quebrar LibraryLive, podar core_components, mover lógica
  pura, reestruturar componentes. *Prova:* testes das funções puras extraídas.
- **Fase 4 — Acabamento + a11y final + verificação:** checklist §6 no DOM; gate
  completo; auditoria de contraste documentada nos comentários dos tokens.

Cada fase entra na `main` por ff-merge, com `git pull --rebase` antes (o dono edita
em paralelo no modo aéreo), sem atribuição de Claude.

---

## 9. Estratégia de verificação

- **Gate** a cada fase: `mix format` · `mix credo --strict` · `mix test` ·
  `mix dialyzer`.
- **App real** (preview): ler CSS computado (`text-transform`, `box-shadow`,
  contraste de cor via cache/DOM — não screenshot), checar foco por teclado, mobile
  375px, e validar a ausência do azul daisyUI no `<html>`.
- **Sem regressão de comportamento:** os 282 testes seguem verdes; nenhuma feature
  muda.
