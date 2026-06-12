# Fase 0 — resultados dos spikes

## Pré-requisitos de sistema (Task 0.2)

| ferramenta | versão | instalação |
|---|---|---|
| ffmpeg  | 8.1.1 | `brew install ffmpeg` |
| ffprobe | 8.1.1 | (incluso no ffmpeg) |
| cargo   | 1.96.0 (rustc 1.96.0) | `brew install rustup` + `rustup default stable` |

Nota: a fórmula `rustup` é keg-only e o `~/.zshrc` do dono **não** foi
modificado (decisão de política da sessão). Para ter `cargo` no PATH de
shells interativos, adicionar manualmente:

```sh
export PATH="$(brew --prefix rustup)/bin:$HOME/.cargo/bin:$PATH"
```

Os comandos de build deste repositório que precisam do cargo exportam esse
PATH inline.

## Spike golden_mask (Task 0.7) — descoberta de campo

FAIL inicial: 3,6% dos pixels divergiam da máscara da rembg, concentrados na
cabeça do condutor (região ambígua: cabelo claro em fundo claro). Debug
sistemático (scripts golden_mask_debug.exs, dump_input_d0.exs, cross_check.py,
resampler_test.py):

- `largest_component` e troca de canais RGB/BGR descartados (máscara tem 1
  componente; canais corretos).
- Runtime descartado: o MESMO input no Ortex (ORT 1.19) e no onnxruntime
  1.26 difere no máximo 3,6e-5 — runtimes são equivalentes.
- **Causa raiz:** o resize por interpolação do OpenCV (`INTER_LANCZOS4`,
  `INTER_LINEAR`) **não faz anti-aliasing no downscale** (kernel fixo); o
  PIL escala o filtro pelo fator (anti-aliased). O aliasing do input
  320×320 desloca a predição do U²-Net na região ambígua.
- **Fix:** `INTER_AREA` no downscale do input → PASS (diff médio 0,254/255;
  0,1% dos pixels > 5/255). Upscale da máscara permanece `LANCZOS4`
  (caminho validado pelo experimento).

Consequência normativa: `U2Net.preprocess` (Fase 1) usa `INTER_AREA`;
contrato §4 e plano atualizados.

## Benchmark de segmentação (Task 0.9)

Medido com `mix run scripts/spikes/bench_segmenter.exs` em 2026-06-12
(Apple M4 Pro): 10 frames reais de `exemplos/entrada/clip.mp4` a 640px,
warm-up descartado.

| medida | ms/frame |
|---|---|
| u2net (pré + inferência + pós) | 309,9 |
| u2netp (pré + inferência + pós) | 160,5 |
| trace_edges (ops Evision) | 2,3 |

Speedup u2netp vs u2net: **1,9x** — abaixo do critério de 2x do plano para
fixar u2netp como default do vídeo. Em termos práticos (15 fps):
clipe de 30 s ≈ 2,4 min com u2net vs ≈ 1,3 min com u2netp.

**Decisão (dono do projeto, gate da Fase 0):** <pendente — ver conversa>

Aprendizados de API registrados nesta task:
- `Exile.stream!` + `Stream.take/2` quebra o pipe no meio (ffmpeg morre com
  Broken pipe e o stream levanta AbnormalExit) — limitar sempre no produtor
  (`-frames:v`/`-t` no ffmpeg).
- Evision 0.2.x não expõe `cv::bitwise_and/or`; para máscaras 0/255 usar
  `Evision.min/2` (AND) e `Evision.max/2` (OR) — semântica idêntica.
