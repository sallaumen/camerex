# Camerex

Identidade visual e pipelines de processamento de mídia para um site de forró.
Transforma fotos e vídeos reais de dança em **rotoscopia neon** — contorno
luminoso fiel ao corpo humano — e define um sistema de bonequinhos vetoriais
para ilustrar papéis de dança. **Tudo determinístico e local: zero IA
generativa, zero APIs pagas.**

Este repositório é a referência para a próxima fase: criação de um projeto
Elixir (possivelmente migrando estes protótipos Python). Os scripts Python
funcionam e produzem os exemplos em `exemplos/saida/`.

---

## 1. Contexto do produto

Site de forró que precisa ilustrar passos e técnica **sem expor a imagem real
do autor**. Princípios inegociáveis da identidade:

- **Papéis, não gêneros.** Quem aparece é o *condutor* e o *conduzido* —
  nunca "homem e mulher". Nenhum marcador visual de gênero (cabelo, vestido,
  silhueta). A diferenciação é por **cor** e por **um acessório cultural**.
- **Cores fixas por papel:**
  - Condutor: laranja vibrante `#FF6B35` (sombra/membro de trás `#C84E1E`)
  - Conduzido: verde-petróleo `#0F8A7D` (sombra `#0A5F55`)
  - Em fundo escuro, sobem um tom: `#FF8A5C` / `#2BC4B2` (efeito neon real)
  - Chapéu de couro nordestino: **sempre marrom couro `#7B4B28`**, usado
    **só pelo condutor** — é o marcador visual do papel junto com a cor.
- **Fundos do site:** bege `#F2EBDD` (claro) e verde-escuro `#1E3D32`
  (seções dark, onde o neon brilha de verdade).

## 2. O que existe aqui

```
camerex/
├── python/
│   ├── foto_para_neon.py    # foto -> rotoscopia neon (imagem)
│   ├── video_para_neon.py   # vídeo -> rotoscopia neon (quadro a quadro)
│   └── requirements.txt
├── design/
│   ├── estilo-bonequinhos-forro.html   # style guide dos bonequinhos (rig v4)
│   ├── pose1-abraco-fechado.svg
│   ├── pose2-dois-pra-la.svg
│   └── geradores/                      # geradores Python dos SVGs acima
└── exemplos/
    ├── entrada/   # mídia de teste (Wikimedia Commons, ver §7)
    └── saida/     # resultados de referência (golden files candidatos)
```

### 2.1 Pipeline foto → neon (`foto_para_neon.py`)

Etapas (cada uma é uma função pura candidata a porta na migração):

1. **`segment`** — segmentação da(s) pessoa(s) com `rembg` (modelo U²-Net,
   ONNX, roda em CPU).
2. **`largest_component`** — mantém só o maior componente conectado da
   máscara (descarta transeuntes/fundo).
3. **`trace_edges`** — CLAHE (equalização adaptativa) + filtro bilateral +
   Canny *dentro* da máscara + contorno da silhueta + fechamento morfológico
   + dilatação. CLAHE é essencial: **roupa escura em fundo escuro não gera
   dobras internas sem ele**.
4. **`neon_compose`** — composição por **MÁXIMO** entre linha e halos
   (blur gaussiano σ=3 e σ=8). Nunca somar: a soma estoura os canais e
   destrói o matiz (laranja virava creme — bug real encontrado e corrigido).
5. **`neon_duotone`** — variante com cor por papel. **Atenção: a versão
   atual divide por posição-x (heurística de demo).** Produção exige
   segmentação por instância (uma máscara por pessoa). Está no roadmap.

Uso: `python3 foto_para_neon.py entrada.jpg saida.png`

### 2.2 Pipeline vídeo → neon (`video_para_neon.py`)

Mesmo algoritmo por frame + 4 mecanismos específicos de vídeo:

1. **Sessão de segmentação reutilizada** — carregar o modelo 1x, não N.
2. **EMA na máscara** (`mask_ema=0.45`) — sem isso a silhueta treme
   (flicker) entre frames.
3. **Rastro de luz só no halo** (`trail_decay=0.6..0.8`) — o traço nítido é
   sempre do frame atual; só o brilho deixa esteira decaindo. Acumular a
   linha nítida gera "casca de cebola" de contornos (bug real corrigido).
4. **Subject-lock por consistência temporal** (`consistent_component`) —
   escolhe o componente com maior sobreposição com a máscara do frame
   anterior, não o maior. Impede a segmentação de "pular" para outra pessoa
   no meio do vídeo (bug real corrigido).

Saída encodada via ffmpeg em H.264/yuv420p — **dimensões precisam ser
pares** (o resize já arredonda a altura).

Uso: `python3 video_para_neon.py entrada.mp4 saida.mp4`
Performance: ~1–1,5 s/frame em CPU (U²-Net). 30 s @ 15 fps ≈ 8–10 min.

Lição de campo: fonte escura/ruidosa (240p, roupa preta em piso escuro) é
adversarial para qualquer segmentador. **Filmar com luz razoável e contraste
figura/fundo resolve 90% dos problemas.** Há um clareamento de sombras
automático para cenas escuras (média de luma < 70), mas é paliativo.

### 2.3 Bonequinhos vetoriais (`design/`)

Linha paralela à rotoscopia: rig de cápsulas SVG para ilustrações didáticas.
Conceito central: **tronco em duas peças** — barra do ombro e barra do
quadril como elementos explícitos que inclinam/deslocam de forma
independente. Isso torna desenhável a *dissociação* (a técnica das "duas
linhas" do forró). Membro de trás em tom de sombra sólido (estilo Just
Dance), nunca opacidade (opacidade faz blend barrento em fundo escuro —
bug real corrigido). O rig mapeia 1:1 nos landmarks do MediaPipe (pares de
ombro/quadril viram as barras), preparado para um futuro pipeline
foto → pose → boneco.

## 3. Migração para Elixir — mapa sugerido

O ecossistema Elixir cobre tudo isto hoje:

| Python (atual)            | Elixir (alvo)                                  |
|---------------------------|------------------------------------------------|
| `rembg` (U²-Net `.onnx`)  | **Ortex** (ONNX Runtime) — o mesmo arquivo `.onnx` roda; pré/pós-processamento em Nx |
| `cv2` (OpenCV)            | **Evision** (bindings OpenCV p/ Elixir): CLAHE, bilateral, Canny, morfologia, connectedComponents, GaussianBlur |
| `numpy`                   | **Nx** (tensores; composição por máximo é `Nx.max/2`) |
| leitura/escrita de vídeo + encode | **ffmpeg via `System.cmd/3`** (simples) ou **Membrane** (se virar streaming/produto) |

Arquitetura sugerida (hexagonal, alinhada ao estilo do dono do projeto):

- **Domínio puro** (`Camerex.Neon`): funções Nx sem I/O — `trace_edges/2`,
  `compose/3`, `temporal_smooth/3`. 100% testável sem modelo.
- **Portas**: `Camerex.Ports.Segmenter` (behaviour: `segment(image) ::
  {:ok, mask}`), `Camerex.Ports.VideoIO`.
- **Adapters**: `Segmenter.Ortex` (produção), `Segmenter.Fixture` (testes —
  devolve máscaras gravadas), `VideoIO.Ffmpeg`.

### Estratégia TDD para a migração

1. **Golden files**: `exemplos/entrada/` + `exemplos/saida/` são as
   fixtures iniciais. Teste de paridade: saída Elixir ≈ saída Python
   (tolerância por pixel, ex. diff médio < 2/255), etapa por etapa — máscara,
   bordas, composição — antes do pipeline inteiro.
2. **Testes de propriedade** (StreamData):
   - matiz da linha == cor do papel em todo pixel de linha (pega o bug do
     estouro de canal);
   - área da máscara não varia mais que X% entre frames consecutivos (pega
     o bug do subject-switching);
   - dimensões de saída sempre pares.
3. **Unidade do domínio puro primeiro** (Nx, sem ONNX), depois adapters
   com fixtures, integração por último.

## 4. Roadmap

- [ ] **Segmentação por instância** (uma máscara por pessoa) → cor por papel
      correta no duotone. Candidatos: YOLO (caixa por pessoa + rembg por
      caixa) ou SAM. Critério: manter local/CPU se possível.
- [ ] Pipeline foto → pose (MediaPipe) → rig de cápsulas SVG (ilustrações
      didáticas automáticas a partir de fotos reais).
- [ ] CLI unificada (`camerex foto ...` / `camerex video ...`).
- [ ] Processamento a cada N frames + interpolação (performance em vídeos
      longos); GPU opcional.
- [ ] Variante de saída SVG vetorial da rotoscopia (potrace sobre as bordas)
      para usar inline no site.

## 5. Como rodar os protótipos Python

```bash
cd python
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python3 foto_para_neon.py ../exemplos/entrada/casal.jpg /tmp/neon.png
python3 video_para_neon.py ../exemplos/entrada/clip.mp4 /tmp/neon.mp4
```

Requisitos de sistema: `ffmpeg` no PATH (para vídeo). Primeiro run baixa o
modelo U²-Net (~176 MB) para `~/.u2net/`.

## 6. Decisões registradas (resumo do processo)

1. SVG geométrico (palitos → cápsulas) é ótimo para *ilustração didática*,
   mas não alcança organicidade humana — para "parecer gente de verdade",
   **traçar gente de verdade** (rotoscopia determinística).
2. IA generativa foi avaliada (Replicate MCP, Pollinations) e descartada
   para o núcleo: custo/instabilidade sem ganho de fidelidade. Pode voltar
   como camada opcional de estilização (ControlNet sobre as bordas), nunca
   como fonte de anatomia.
3. Composição neon por máximo, não soma (preserva matiz).
4. CLAHE antes do Canny (dobras em tecido escuro).
5. Profundidade por cor de sombra sólida, não opacidade.
6. Vídeo: EMA na máscara, rastro só no halo, subject-lock por IoU temporal.

## 7. Atribuição das mídias de teste

Mídias em `exemplos/entrada/` vêm do Wikimedia Commons e são usadas aqui
apenas como fixtures de teste. Licenças e autoria nas páginas de origem:

- Foto: https://commons.wikimedia.org/wiki/File:A_couple_dancing_Tango_(4728808529).jpg
- Vídeo: https://commons.wikimedia.org/wiki/File:Tango_Dancing_at_the_Ambassadors_Reception.webm

Para o site em produção, substituir por mídia própria.
