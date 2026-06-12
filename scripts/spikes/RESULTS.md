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
