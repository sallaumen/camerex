# Redesign "neon refinado" — plano de implementação

> **Para quem executa:** plano por tarefas com checkbox (`- [ ]`). Cada tarefa é
> auto-contida, entra na `main` por ff-merge (com `git pull --rebase` antes — o dono
> edita em paralelo no modo aéreo) e **sem atribuição de Claude**. Referência de
> design: [design doc](2026-06-22-redesign-neon-refinado.md).

**Goal:** elevar a UI/UX do camerex a nível sênior mantendo a identidade neon, via um
design system tokenizado, kit de componentes coeso, estrutura de app e acabamento
acessível — sem mudar nenhuma funcionalidade.

**Architecture:** um único tema dark-verde no `@theme` do `app.css` (daisyUI removido);
primitivos em `CamerexWeb.UI`; `LibraryLive` reorganizado num shell de 3 colunas +
lógica pura extraída. Tudo aplicado em fases independentes e verificáveis.

**Tech Stack:** Phoenix LiveView, HEEx, Tailwind v4 (`@theme`), CSS custom, Heroicons.

## Convenções de verificação (toda tarefa)
- **Gate:** `mix format` · `mix credo --strict` · `mix test` · `mix dialyzer` verdes.
- **App real (preview):** subir server na 4000, ler **CSS computado** (não screenshot)
  para asserir cor/`text-transform`/`box-shadow`/foco; checar mobile 375px; confirmar
  `getComputedStyle(document.documentElement)` **sem** hue 252–292 (azul daisyUI).
- **Sem regressão:** os 282 testes seguem verdes; nenhuma feature muda.
- **Commit:** um por tarefa (ou subgrupo coeso), mensagem conventional em pt, ff-merge
  na `main`.

---

## FASE 0 — Fundação (tokens + matar daisyUI + base 16px)

### Tarefa 0.1 — Reescrever o `@theme` com o sistema de tokens completo
**Files:** Modify `assets/css/app.css:12-23` (bloco `@theme`)

- [ ] **Passo 1:** Substituir o `@theme` atual pelo conjunto completo do design doc §3:
```css
@theme {
  /* superfícies (escada de elevação por luz) */
  --color-cx-well: #0c1612;
  --color-cx-bg: #101a15;
  --color-cx-surface: #1a2a22;
  --color-cx-elevated: #25392f;
  /* bordas (2 papéis) */
  --color-cx-hairline: #2e493c;     /* decorativa */
  --color-cx-border: #547f6b;       /* funcional/UI ≥3:1 */
  /* texto (3 níveis) */
  --color-cx-text: #d3e5db;
  --color-cx-text-dim: #a1b7ac;
  --color-cx-text-faint: #7c9287;
  /* acentos + estados */
  --color-cx-teal: #2bc4b2;
  --color-cx-teal-strong: #1fae9e;
  --color-cx-orange: #ff8e59;
  --color-cx-success: #2bc4b2;
  --color-cx-warning: #e8c34a;
  --color-cx-danger: #f06a5e;
  --cx-teal-rgb: 43 196 178;
  /* raio */
  --radius-control: 0.375rem;
  --radius-card: 0.625rem;
  --radius-lg: 1rem;
  /* motion */
  --cx-dur-fast: 120ms; --cx-dur-base: 180ms; --cx-dur-slow: 220ms;
  --cx-ease-out: cubic-bezier(.16,1,.3,1);
  --cx-ease-in-out: cubic-bezier(.65,0,.35,1);
  /* tipografia (Tailwind v4 lê --text-*--line-height / --letter-spacing) */
  --text-display: 2rem;    --text-display--line-height: 1.15; --text-display--letter-spacing: -0.02em;
  --text-h1: 1.5rem;       --text-h1--line-height: 1.2;       --text-h1--letter-spacing: -0.015em;
  --text-h2: 1.25rem;      --text-h2--line-height: 1.3;       --text-h2--letter-spacing: -0.01em;
  --text-body: 1rem;       --text-body--line-height: 1.5;
  --text-label: 0.8125rem; --text-label--line-height: 1.4;    --text-label--letter-spacing: 0.01em;
  --text-caption: 0.75rem; --text-caption--line-height: 1.35; --text-caption--letter-spacing: 0.02em;
}
/* glow assinatura (fora do @theme, são sombras compostas) */
:root {
  --cx-glow-signature: 0 0 2px rgb(var(--cx-teal-rgb)/.8), 0 0 8px rgb(var(--cx-teal-rgb)/.42), 0 0 22px rgb(var(--cx-teal-rgb)/.18);
  --cx-glow-hover: 0 0 2px rgb(var(--cx-teal-rgb)/.9), 0 0 10px rgb(var(--cx-teal-rgb)/.55), 0 0 28px rgb(var(--cx-teal-rgb)/.3);
  --cx-glow-status: 0 0 6px rgb(232 195 74/.45), 0 0 16px rgb(232 195 74/.22);
}
```
- [ ] **Passo 2:** `mix assets.build` e confirmar que `app.css` gera as utilities
  `bg-cx-well`, `bg-cx-elevated`, `text-cx-text-faint`, `border-cx-hairline`,
  `bg-cx-danger` (grep no `priv/static/assets/css/app.css`).
- [ ] **Passo 3:** Commit `feat(ui): escada de tokens do tema neon refinado no @theme`.

### Tarefa 0.2 — Matar o daisyUI e fixar dark no `<html>`
**Files:** Modify `assets/css/app.css:234-321`, `lib/camerex_web/components/layouts/root.html.heex`, `lib/camerex_web/components/layouts.ex:97-132`

- [ ] **Passo 1:** Remover os dois blocos `@plugin "../vendor/daisyui-theme" {...}`
  (dark e light, `app.css:241-313`) e o `@plugin "../vendor/daisyui"` (`:237-239`)
  — confirmar antes que nenhuma classe daisyUI (`.btn .input .alert .card .badge`)
  sobra fora de `core_components.ex` (grep). Manter os `@custom-variant` e o
  `@plugin heroicons`.
- [ ] **Passo 2:** Em `root.html.heex`: trocar `<html lang="en">` por
  `<html lang="pt-BR" class="dark" style="color-scheme: dark">` e **remover** o
  `<script>` de tema (linhas 11-39).
- [ ] **Passo 3:** Remover `theme_toggle/1` de `layouts.ex` (não é usado).
- [ ] **Passo 4 (verificação no app real):** subir server; `preview_eval`
  `getComputedStyle(document.documentElement).backgroundColor` e confirmar matiz
  verde (não `oklch(.30 .016 252)`); página renderiza sem erro.
- [ ] **Passo 5:** Commit `fix(ui): arranca o tema daisyUI azul e fixa dark no html`.

### Tarefa 0.3 — Base 16px + bloco prefers-reduced-motion
**Files:** Modify `assets/css/app.css:27-29` e final do arquivo

- [ ] **Passo 1:** Trocar `html { font-size: 18px }` por `16px`.
- [ ] **Passo 2:** Adicionar no fim do `app.css`:
```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: .01ms !important; animation-iteration-count: 1 !important;
    transition-duration: .01ms !important; scroll-behavior: auto !important;
  }
}
```
- [ ] **Passo 3 (verificação):** preview — confirmar densidade menor; nada quebrou.
- [ ] **Passo 4:** Commit `feat(ui): base tipográfica 16px + guarda de reduced-motion`.

### Tarefa 0.4 — Tokenizar o bloco `.neon-*`/`.cx-*` e limpar órfãos
**Files:** Modify `assets/css/app.css:35-232`; `lib/camerex_web/components/library_components.ex:91`

- [ ] **Passo 1:** Trocar todo hex literal por `var(--color-cx-*)` em
  `.neon-badge/.neon-card/.neon-empty/.neon-cta` e nos `rgb(43 196 178/…)` por
  `rgb(var(--cx-teal-rgb)/…)`. Aplicar a escala de surface (cards `surface`,
  `.cx-section` → `surface` em vez do `color-mix`), hairline 1px e os raios em token.
- [ ] **Passo 2:** Remover `.neon-swatch`/`.neon-swatch-selected` órfãos (grep
  confirma só `cx-swatch` em uso). Trocar `accent-[#2BC4B2]` por classe do token.
- [ ] **Passo 3:** Racionar glow: remover `box-shadow` de repouso de
  `.neon-swatch`/`.cx-swatch`/`.cx-range` track; mover halo do thumb para
  `:focus-visible`/`:active` via `--cx-glow-signature`; `.neon-card:hover` perde o
  drop-shadow (vira `border-color: teal` + `translateY(-1px)` + `cx-elevated`).
- [ ] **Passo 4:** topbar teal — `assets/js/app.js:36`:
  `barColors:{0:"#2bc4b2"}`, `shadowColor:"rgba(43,196,178,.4)"`, `barThickness:2`.
- [ ] **Passo 5 (verificação):** preview — glow só em CTA/foco; cards com hairline;
  `getComputedStyle` do thumb em repouso sem `box-shadow` neon.
- [ ] **Passo 6:** Commit `refactor(ui): tokeniza neon, raciona glow, limpa CSS órfão`.

---

## FASE 1 — Kit de componentes `CamerexWeb.UI`

> Criar `lib/camerex_web/components/ui.ex` (módulo `CamerexWeb.UI`) e importá-lo em
> `camerex_web.ex`. Cada componente: attrs do design doc §4, estados
> hover/focus-visible(anel sólido teal 2px)/active(scale .97)/disabled/loading.
> Verificação por tarefa: renderizar via teste de componente (`render_component/2`)
> asserindo classes/atributos de estado, + preview do estado real.

### Tarefa 1.1 — Foco global + base do kit
**Files:** Create `lib/camerex_web/components/ui.ex`; Modify `assets/css/app.css`, `lib/camerex_web/camerex_web.ex`
- [ ] Adicionar no `app.css` o foco padrão:
  `:where(a,button,[role=button],input,select,textarea):focus-visible{ outline:2px solid var(--color-cx-teal); outline-offset:2px }`.
- [ ] Criar `CamerexWeb.UI` vazio + `import CamerexWeb.UI` em `camerex_web.ex` (html_helpers).
- [ ] Commit `feat(ui): módulo CamerexWeb.UI + foco visível global`.

### Tarefa 1.2 — `button/1` (+ classes `.cx-btn*`)
**Files:** Modify `ui.ex`, `app.css`; Test `test/camerex_web/components/ui_test.exs`
- [ ] `button/1` com `variant` (primary|secondary|ghost|danger), `size` (sm|md),
  `loading`, slot. Primário: teal fill + `--cx-glow-signature` (intensifica no hover);
  secundário/ghost: sem glow; danger: `cx-danger`. `:active{scale(.97)}`,
  `disabled` (opacity+cursor). Loading usa `phx-disable-with` quando submit.
- [ ] Teste: `render_component(&button/1, variant: :primary)` contém a classe do CTA e
  `render_component(..., disabled: true)` tem `disabled`.
- [ ] Commit `feat(ui): componente button com variantes e estados`.

### Tarefa 1.3 — `input/1` e `select/1` (`.cx-input`)
**Files:** Modify `ui.ex`, `app.css`; Test idem
- [ ] Classe `.cx-input` token-based (border `cx-border`, raio control, foco teal).
  `input/1`/`select/1` envolvendo o nativo. Estado de erro com `cx-danger`.
- [ ] Commit `feat(ui): input e select padronizados`.

### Tarefa 1.4 — `badge/1` (unifica status_badge + type-chip)
**Files:** Modify `ui.ex`, `app.css`, `neon_components.ex`
- [ ] `badge/1` `tone: neutral|info|success|warning|danger` + `processing` (glow+pulse
  dentro de reduced-motion). `status_badge` e o type-chip passam a ser instâncias.
- [ ] Commit `feat(ui): badge único para status e tipo`.

### Tarefa 1.5 — `card/1`, `media_frame/1`, `progress/1`
**Files:** Modify `ui.ex`, `app.css`
- [ ] `card/1` (surface+hairline, `interactive?` sobe p/ elevated+borda teal).
  `media_frame/1` (a moldura `max-h-[72vh]` repetida 5×). `progress/1`
  (`role=progressbar`, `aria-valuenow`, `transform: scaleX()` com transição slow).
- [ ] Extrair helper único de pct (remover `pct/1` e `progress_pct/1` duplicados).
- [ ] Commit `feat(ui): card, media_frame e progress com pct unificado`.

### Tarefa 1.6 — `modal/1`, `close_button/1`, e slider/switch/swatch/section promovidos
**Files:** Modify `ui.ex`, `app.css`, `convert_panel.ex`
- [ ] `modal/1` (overlay, `aria-modal`, esc, click-away, enter/exit via `JS`, foco
  preso por hook, restaura foco no trigger). `close_button/1` único. Promover
  `slider/1`/`switch/1`/`swatch/1`/`section/1` de `convert_panel` (privados) para o kit.
- [ ] Commit `feat(ui): modal, close_button e controles promovidos ao kit`.

---

## FASE 2 — Superfícies + estrutura

### Tarefa 2.1 — Shell de 3 colunas fixas
**Files:** Modify `lib/camerex_web/live/library_live.ex:506-520` (e o `render/1`)
- [ ] Trocar `flex min-h-screen w-full gap-4 p-4` por
  `grid h-screen grid-cols-[16rem_minmax(0,1fr)_auto]`: rail (col 1, `overflow-y-auto`),
  palco (col 2, fundo `well`, header fixo no topo), inspetor (col 3, ~380px,
  `overflow-y-auto`, aparece com convert/detail). Cada coluna rola sozinha.
- [ ] Verificação: preview — 3 regiões com scroll independente; sem scroll único.
- [ ] Commit `feat(ui): shell de 3 colunas (rail · palco · inspetor)`.

### Tarefa 2.2 — Poço de preview + status bar (perf)
**Files:** Modify `library_components.ex:301-341` (perf_dashboard), `library_live.ex`
- [ ] `perf_dashboard` vira faixa de status fina (`h-7`) na base do shell, medidores
  inline; remover `fixed z-50`. Preview/thumbs usam `bg-cx-well`; xadrez quando
  `transparent_bg`.
- [ ] Commit `feat(ui): status bar inferior + poço de preview com xadrez`.

### Tarefa 2.3 — Slider de revelação antes/depois
**Files:** Modify `detail_panel.ex:40-92`; Create hook em `assets/js/` (`BeforeAfter`)
- [ ] Hook JS `BeforeAfter`: container `relative`, img "depois" embaixo (full), "antes"
  por cima com `clip-path`/width por `--reveal` (range 0-100); handle (linha 2px teal +
  círculo 28px) arrastável por pointer events; `:active` scale(.92)+glow (gesto ativo).
  Toggle "revelador ↔ lado a lado". Vídeo segue lado a lado.
- [ ] Verificação: preview com 1 item `done` (ou stub) — arrastar revela.
- [ ] Commit `feat(detail): slider de revelação antes/depois`.

### Tarefa 2.4 — Migrar superfícies pro kit + flash tokenizado + responsivo
**Files:** Modify `library_components.ex`, `convert_panel.ex`, `library_live.ex`, `core_components.ex:71-77`
- [ ] Trocar botões/inputs/cards/badges/modais inline pelos componentes do kit.
  Reescrever `flash/1` com tokens `cx-*` (sem `alert-*`). Ritmo de espaçamento único
  (24/12/8). `tabular-nums` nos valores de slider. Passar `%RenderParams{}` inteiro ao
  `convert_panel` (acaba o fan-out de 16 attrs em `library_live.ex:634-660`).
- [ ] Responsivo: colapsar colunas (<lg): inspetor vira overlay/bottom-sheet, rail vira
  drawer; modal responsivo. Verificar em 375px.
- [ ] Commit(s) por superfície `refactor(ui): <superfície> usa o kit`.

---

## FASE 3 — Organização do código

### Tarefa 3.1 — Extrair lógica pura de cor do LiveView
**Files:** Create `lib/camerex/color_json.ex` (ou em `Camerex.Parser.Layers`); Modify `library_live.ex:1097-1157`; Test `test/camerex/color_json_test.exs`
- [ ] Mover `hex_to_rgb`, `colors_to_json`, `parse_colors_json`, `build_layer_colors`,
  `json_color` (funções puras) para o módulo; LiveView passa a chamá-las.
- [ ] **Teste primeiro** (TDD aqui faz sentido — é função pura): round-trip
  hex↔rgb e parse/serialize do JSON de cores. Rodar → falha → implementar → passa.
- [ ] Commit `refactor: extrai ColorJSON puro do LibraryLive (testável)`.

### Tarefa 3.2 — Podar core_components + extrair modais/topbar + mover versioned_media_url
**Files:** Modify `core_components.ex`, `library_live.ex:722-859`, `neon_components.ex:36-43`, `lib/camerex/workspace.ex`
- [ ] Remover button/input/table/list/header mortos de `core_components` (manter
  icon/flash/helpers). Os 3 modais inline → `<.modal>` do kit. Mover
  `versioned_media_url` para `Workspace`.
- [ ] Commit `refactor(web): poda core_components e consolida modais no kit`.

### Tarefa 3.3 — Reorganizar componentes em ui/ vs library/
**Files:** mover arquivos para `components/ui/` e `components/library/`
- [ ] Estrutura: `components/ui/` (DS) vs `components/library/` (feature). Ajustar
  `embed`/imports. Sem mudança visual.
- [ ] Commit `refactor(web): separa design system de componentes de feature`.

---

## FASE 4 — Acabamento + acessibilidade final + verificação

### Tarefa 4.1 — Checklist WCAG 2.2 (design doc §6)
**Files:** vários (ajustes pontuais)
- [ ] Alvos ≥24px (checkbox de seleção, thumb do slider, ✕ de preset). Alt útil
  (`"antes — #{arquivo}"`); decorativas `aria-hidden`. Foco preso no modal +
  restauração. Estado nunca só por cor (ícone no badge crítico; severidade no perf).
- [ ] **Verificação no DOM:** foco por teclado visível em 100% dos interativos;
  contrastes dos pares cor/fundo conferidos; `lang=pt-BR`.
- [ ] Commit `fix(a11y): WCAG 2.2 — foco, alvos, alt, modal, cor+ícone`.

### Tarefa 4.2 — Passada final de verificação e prova
- [ ] Gate completo verde. Preview desktop + mobile 375px; screenshots de prova das
  superfícies-chave; `getComputedStyle(html)` sem azul; glow só nos pontos previstos.
- [ ] Atualizar memória com o que ficou não-óbvio.

---

## Self-review (cobertura do spec)
- §3 tokens → Fase 0.1/0.3. §7 matar daisyUI → 0.2. Glow racionado → 0.4. §4 kit →
  Fase 1 (1.1–1.6). §5 superfícies/shell/reveal/status/modal/responsivo → Fase 2.
  §7 organização (LiveView/core_components/módulos) → Fase 3. §6 a11y → Fase 4.1.
  §9 verificação → convenções + 4.2. Sem lacunas; sem placeholders de ação vaga.

## Handoff de execução
Plano salvo. Execução recomendada: **inline com checkpoints por fase** (cada fase é um
bloco coeso, validado no app real e commitado), dada a edição paralela do dono no
`library_live.ex` (subagentes em paralelo no mesmo arquivo dariam conflito). Workflow
multi-agente só onde for paralelizável sem tocar arquivos compartilhados.
