# Camerex

App **Elixir/Phoenix 100% local** que transforma fotos e vídeos reais de
dança em **rotoscopia neon** — contorno luminoso fiel ao corpo, com halos e
rastro de luz. Pipeline determinístico (U²-Net + OpenCV + Nx): **zero IA
generativa, zero APIs pagas, nada sobe para a nuvem.**

## Exemplos

Resultados de referência em [`exemplos/saida/`](exemplos/saida/):

- [`neon_duotone_final.png`](exemplos/saida/neon_duotone_final.png) — foto,
  preset duotone laranja/teal
- [`neon_teal_final.png`](exemplos/saida/neon_teal_final.png) — foto, preset mono teal
- [`tango_neon.mp4`](exemplos/saida/tango_neon.mp4) — vídeo com rastro de luz

## Pré-requisitos (macOS)

```sh
brew install ffmpeg rustup
rustup default stable   # Rust só compila o NIF do Ortex no build; não roda em runtime
```

A fórmula `rustup` do Homebrew é keg-only; para `cargo` no PATH dos seus
shells, adicione ao `~/.zshrc`:

```sh
export PATH="$(brew --prefix rustup)/bin:$HOME/.cargo/bin:$PATH"
```

Erlang/OTP + Elixir (ex.: `brew install elixir` ou asdf). O primeiro
`mix setup` exige rede (baixa os binários do ONNX Runtime e do OpenCV).

## Instalação e uso

```sh
mix setup            # deps + assets
mix camerex.setup    # baixa u2net.onnx (176 MB) e u2netp.onnx (4,7 MB), com MD5
mix phx.server       # http://localhost:4000 (escuta só em 127.0.0.1)
```

Na interface: solte uma foto ou vídeo na dropzone, escolha um dos 6 presets
de cor (mono ou duotone), ajuste **halo**, **rastro** e **detalhe**, e
acompanhe o progresso na galeria (para vídeo há "prévia de 1 frame" antes de
converter). Cada item tem página própria com antes/depois, download,
"re-converter com ajustes" (cria um item novo) e exclusão. Se faltar ffmpeg
ou modelo, um banner na galeria mostra o comando de correção.

## Como funciona

1. **Segmentação** da pessoa com U²-Net via Ortex/ONNX (modelo `u2net`;
   a prévia usa o `u2netp`, mais leve).
2. **Bordas**: CLAHE + filtro bilateral + Canny dentro da máscara +
   contorno da silhueta (Evision/OpenCV).
3. **Composição por máximo** entre linha e halos gaussianos — o matiz da
   linha é exatamente a cor do preset, nunca estoura.
4. **Vídeo**: máscara suavizada por EMA (anti-flicker), subject-lock por
   sobreposição temporal, rastro de luz decaindo só no halo, duotone com
   split estabilizado. Fps alvo = `min(fps de origem, 15)` com duração
   preservada; largura de trabalho 640 px.

## Workspace (sem banco de dados)

Cada conversão é uma pasta autocontida — apagar o item é apagar a pasta:

```
workspace/
├── items/<id>/        # manifest.json, original.*, neon.*, thumb*.jpg
└── tmp/               # uploads em trânsito e prévias (limpo no boot)
```

A galeria escaneia o disco; jobs interrompidos por restart viram
`interrupted` e podem ser reprocessados pela UI.

## CLI

Conversão direta arquivo → arquivo, sem criar item na galeria:

```sh
mix camerex.foto IN OUT [--preset ID] [--halo 0..1] [--detail 0..1]
mix camerex.video IN OUT [--preset ID]
```

Presets: `forro-laranja`, `forro-teal`, `forro-duotone`, `pulp`, `miami`, `ouro`.

## Desenvolvimento

```sh
mix test                  # suíte rápida (segmentação via fixtures)
mix test --include model  # + paridade golden com o modelo ONNX real
```

- `python/` — protótipos de referência e `gen_goldens.py` (gera os golden
  files de `exemplos/golden/` usados nos testes de paridade).
- `design/` — linha paralela dos bonequinhos vetoriais SVG (roadmap:
  pipeline foto → pose → boneco).
- `scripts/spikes/` — spikes da Fase 0 e `RESULTS.md` com benchmarks e
  descobertas de campo (ex.: por que o downscale usa `INTER_AREA`).

## Atribuição das mídias de teste

Mídias em `exemplos/entrada/` vêm do Wikimedia Commons e são usadas aqui
apenas como fixtures de teste. Licenças e autoria nas páginas de origem:

- Foto: https://commons.wikimedia.org/wiki/File:A_couple_dancing_Tango_(4728808529).jpg
- Vídeo: https://commons.wikimedia.org/wiki/File:Tango_Dancing_at_the_Ambassadors_Reception.webm

Para o site em produção, substituir por mídia própria.
