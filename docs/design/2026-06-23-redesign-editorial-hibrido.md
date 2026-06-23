# Redesign editorial híbrido (2026-06-23)

Avaliação do handoff "Editorial" do Claude Design (zip `Refatoração de página clássica`)
contra o front-end atual ("neon refinado", entregue em 2026-06-22, ver
`2026-06-22-redesign-neon-refinado.md`). Direção escolhida por Lucas: **HÍBRIDO** —
*evolui a identidade, não troca*.

## Princípio do híbrido

O canvas vira **quente e editorial** (superfícies marrom + texto creme/areia + serif de
display nos títulos), mas o **teal sobrevive como a única faísca de marca** (foco, estados
interativos, preenchimentos, CTA), com o **glow reduzido, não eliminado**. A UI quente
recua como papel impresso; o **neon avança** (teal no chrome, cor cheia na arte). É o
princípio editorial "o neon mora na imagem" — com a faísca da marca preservada.

Decisões fixas:
- **Sem segundo acento cromático** (ouro fica de fora do chrome p/ não embolar com o teal).
- **Sem UPPERCASE** — mantém o princípio nº4 do neon refinado ("hierarquia vem de tipo,
  não de caixa-alta"). Foi a 1ª tarefa da sessão (de-shout); não reintroduzir.
- **Re-pass WCAG obrigatório** nos tons quentes (a paleta editorial crua reprova).

## Por que isto é barato e seguro

O neon refinado centralizou tudo em tokens `@theme` no `assets/css/app.css`; os templates
usam só utilitários `cx-*` (zero hex hardcoded no HEEx). Trocar a paleta é reatribuir ~13
valores num lugar. Manter o teal preserva `--color-cx-teal`, que alimenta **todo o
`:focus-visible` global** e os anéis de controle — nenhuma re-derivação de foco necessária.

## Paleta quente derivada (com WCAG calculado — `scripts`/python)

Mantém os **nomes semânticos `cx-*`** (não renomear p/ ink/gold/sand) — re-skin por VALOR.

| Token | Atual (frio) | Híbrido (quente) | Contraste verificado |
|---|---|---|---|
| `--color-cx-well` | #0c1612 | `#0A0907` | poço/palco |
| `--color-cx-bg` | #101a15 | `#100E0B` | canvas |
| `--color-cx-surface` | #1a2a22 | `#17150F` | cards/painéis |
| `--color-cx-elevated` | #25392f | `#1F1C15` | modal (ajustar no preview se ler flat) |
| `--color-cx-border` | #2e493c | `#2A2620` | hairline decorativa (sem mínimo) |
| `--color-cx-border-strong` | #547f6b | `#7A7060` | **3.75:1** vs surface (≥3, WCAG 1.4.11) |
| `--color-cx-text` | #d3e5db | `#F2ECE0` | **16.4:1** vs bg (AAA) |
| `--color-cx-text-dim` | #a1b7ac | `#C9C0AE` | **10.1:1** vs surface (AAA) |
| `--color-cx-text-faint` | #7c9287 | `#A39A89` | **6.5:1** vs bg (sobe de 4.6) |
| `--color-cx-teal` | #2bc4b2 | **mantém** | **8.4:1** vs surface (faísca/foco) |
| `--color-cx-teal-strong` | #1fae9e | mantém | hover/preenchido |
| `--color-cx-warning` | #e8c34a | mantém | dourado já é quente — harmoniza |
| `--color-cx-danger` | #f06a5e | mantém | vermelho único de erro |
| `--color-cx-orange` | #ff8e59 | mantém | acento quente, parcimônia |

NÃO confundir: `lib/camerex/parser/layers.ex` tem `{43,196,178}` (teal) como cor de
contorno **renderizado (a arte)** — **não é token de tema, não tocar**.

## Camada 1 — ganhos sem regressão (theme-agnostic)

Valem em qualquer paleta; são puro ganho.

- **1.1 `param_bar/1` no kit** `CamerexWeb.UI` (rótulo + valor mono + mini-trilho preenchido).
  Hoje o detalhe lista params num `<dl>` cru (`detail_panel.ex:125`). Usar no detalhe e no hero.
- **1.2 Card-herói `@featured`** — 1º item `done` (já vêm ordenados por data). Nova `<section>`
  acima de `#gallery` + componente em `library_components.ex`; `:if` esconde quando vazio.
  Reusa comparador (`BeforeAfter`), `param_bar` e `btn`.
- **1.3 Polish:** glifo no handle + pílulas "antes/depois" no comparador; `::selection`;
  fade+translateY de entrada do modal (CSS → cai no bloco `reduced-motion` existente).
- **1.4 Débito de kit (casa com a Fase 3):** promover `slider/1`, `toggle/1`, `swatch/1`,
  `section/1` de privados em `convert_panel.ex` → `CamerexWeb.UI`; padronizar
  `filter_bar`/`selection_bar` p/ `UI.input`/`UI.select`.

## Camada 2 — pele editorial parcial (o "evolui a identidade")

- **2.1 Tokens quentes** — aplicar a paleta derivada acima no `@theme` (re-skin por valor).
- **2.2 Serif de display** — Newsreader **self-host** (`priv/static/fonts`, `@font-face`,
  `--external:/fonts/*` já existe no esbuild; **sem CDN**). Title-only (logo, títulos de tela,
  nome de arquivo, breadcrumb), plugada na escala `--text-*` existente. Corpo segue system-ui
  (Hanken não vale o peso/FOUT). `font-display:swap` + preload do peso above-the-fold.
- **2.3 Glow reduzido** — diminuir spread/alpha de `--cx-glow-signature/-hover`; manter só no
  CTA + estados ao vivo (badge processing). Repouso continua sem glow.
- **2.4 Re-pass WCAG** — corrigir o teal hardcoded em `assets/js/app.js:132` (topbar) p/ token;
  conferir contraste de todos os tons quentes no preview (computed-CSS, não screenshot).

## Camada 3 — pular / adiar (conflita ou baixo valor)

- Abas de pasta no topo (achata a árvore aninhada; alto risco no `library_live`).
- 5 rotas separadas (desfaz a SPA single-page deliberada).
- 3 presets fixos (regrediria `UserPresets` dinâmico).
- Renomear tokens `cx-*` → ink/gold/sand (churn sem ganho).
- "Pausar fila" (feature de `Jobs`, fora do redesign visual).

## Ordem de execução + disciplina

1. **2.1 tokens quentes** (a evolução mais visível; provo contraste no preview).
2. **2.2 serif** (o "ar editorial").
3. **1.1 param_bar** → **1.2 card-herói** (aterrissam no canvas novo).
4. **2.3 glow reduzido** + **1.3 polish** + **2.4 WCAG/topbar**.
5. **1.4 débito de kit** (limpeza).

Cada incremento: gate verde (`compile -W`, `format`, `test`, `credo`, `dialyzer`) + prova no
preview por computed-CSS/DOM (screenshot não vale p/ cor) + commit direto na `main` sem
atribuição de Claude. Antes de cada commit: `git pull --rebase` (o dono commita em paralelo).
