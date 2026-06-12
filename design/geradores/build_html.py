"""Monta o HTML final v4 a partir do rig de cápsulas validado (gen2)."""
import gen2

poses = gen2.build()
pose1, pose2 = poses["pose1"], poses["pose2"]

# Variante neon: troca sólida de cores (sem opacidade => sem blend barrento)
DARK_MAP = {
    "#F2EBDD": "#1E3D32",   # fundo
    "#FF6B35": "#FF8A5C", "#C84E1E": "#E0622E",   # condutor + sombra
    "#0F8A7D": "#2BC4B2", "#0A5F55": "#0F8A7D",   # conduzido + sombra
    "#7B4B28": "#A2693A",                          # couro
    'opacity="0.07"': 'opacity="0.2"',
}
pose1_dark = pose1
for a, b in DARK_MAP.items():
    pose1_dark = pose1_dark.replace(a, b)

html = f"""<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Estilo · Bonequinhos de Forró — v4</title>
<style>
  :root{{
    --bege:#F2EBDD; --bege-card:#FAF5E9; --borda:#E2D7BF;
    --verde-escuro:#1E3D32; --condutor:#FF6B35; --condutor-sombra:#C84E1E;
    --conduzido:#0F8A7D; --conduzido-sombra:#0A5F55;
    --couro:#7B4B28; --tinta:#2B2A26;
  }}
  *{{ box-sizing:border-box; margin:0; }}
  body{{ background:var(--bege); color:var(--tinta);
    font-family:-apple-system,"Segoe UI",Roboto,sans-serif;
    padding:28px 18px 60px; max-width:980px; margin:0 auto; }}
  h1{{ font-family:Georgia,"Times New Roman",serif; font-weight:400;
    font-size:clamp(26px,4vw,38px); letter-spacing:-0.5px; }}
  .sub{{ margin-top:6px; font-size:14px; opacity:.65; max-width:64ch; }}
  .grid{{ display:grid; grid-template-columns:repeat(auto-fit,minmax(280px,1fr));
    gap:16px; margin-top:28px; }}
  .card{{ background:var(--bege-card); border:1px solid var(--borda);
    border-radius:16px; padding:18px; }}
  .card h2{{ font-size:12px; text-transform:uppercase; letter-spacing:1.4px;
    font-weight:600; opacity:.55; margin-bottom:10px; }}
  .card.dark{{ background:var(--verde-escuro); border-color:var(--verde-escuro); }}
  .card.dark h2{{ color:#fff; opacity:.65; }}
  svg{{ width:100%; height:auto; display:block; border-radius:10px; }}
  .nota{{ font-size:13px; line-height:1.55; opacity:.8; margin-top:10px; }}
  .card.dark .nota{{ color:#fff; opacity:.75; }}
  .swatches{{ display:flex; gap:10px; flex-wrap:wrap; }}
  .sw{{ flex:1; min-width:86px; border-radius:12px; padding:14px 12px 10px;
    color:#fff; font-size:12px; }}
  .sw small{{ display:block; opacity:.85; font-size:11px; margin-top:2px; }}
  .sw.bege-sw{{ color:var(--tinta); border:1px solid var(--borda); }}
</style>
</head>
<body>

<h1>Bonequinhos de Forró — estudo de estilo v4</h1>
<p class="sub">Rig de cápsulas com tronco em duas peças: a linha do ombro e a linha do
quadril são elementos visuais explícitos que inclinam e deslocam de forma independente —
a dissociação da dança, desenhável. Profundidade por tom escuro sólido do membro de trás.
Corpos idênticos e neutros; papéis marcados por cor + chapéu de couro do condutor.</p>

<div class="grid">

  <div class="card">
    <h2>Pose 01 · Abraço fechado</h2>
    {pose1}
    <p class="nota">Cabeças inclinadas uma à outra, peito do conduzido apontado ao
    condutor, mão na lateral da cintura, pés se encontrando ponta a ponta.</p>
  </div>

  <div class="card">
    <h2>Pose 02 · Dois pra lá (quadril)</h2>
    {pose2}
    <p class="nota">Dissociação: linha do ombro nivelada enquanto a pelve desloca e
    inclina — lado do peso mais alto, perna de peso vertical sob a pelve, perna livre
    estendida com pé apontado. A cintura acompanha o quadril, então a coluna entra
    no movimento.</p>
  </div>

  <div class="card">
    <h2>Paleta</h2>
    <div class="swatches">
      <div class="sw" style="background:var(--condutor)">Condutor<small>#FF6B35</small></div>
      <div class="sw" style="background:var(--condutor-sombra)">Sombra<small>#C84E1E</small></div>
      <div class="sw" style="background:var(--conduzido)">Conduzido<small>#0F8A7D</small></div>
      <div class="sw" style="background:var(--conduzido-sombra)">Sombra<small>#0A5F55</small></div>
      <div class="sw" style="background:var(--couro)">Couro<small>#7B4B28</small></div>
      <div class="sw bege-sw" style="background:var(--bege)">Fundo<small>#F2EBDD</small></div>
    </div>
    <p class="nota">Cada papel tem cor principal + tom de sombra sólido para o lado de
    trás do corpo (braço e perna mais distantes), no estilo Just Dance. Sombra sólida
    em vez de opacidade: funciona igual em qualquer fundo.</p>
  </div>

  <div class="card dark">
    <h2>Variante neon · fundo escuro</h2>
    {pose1_dark}
    <p class="nota">Nas seções escuras: #FF8A5C / #2BC4B2, sombras #E0622E / #0F8A7D,
    couro #A2693A.</p>
  </div>

</div>
</body>
</html>
"""

with open("/mnt/user-data/outputs/estilo-bonequinhos-forro.html", "w") as f:
    f.write(html)
with open("/mnt/user-data/outputs/pose1-abraco-fechado.svg", "w") as f:
    f.write(pose1)
with open("/mnt/user-data/outputs/pose2-dois-pra-la.svg", "w") as f:
    f.write(pose2)

# render da variante dark para inspeção
import cairosvg
cairosvg.svg2png(bytestring=pose1_dark.encode(),
                 write_to="/home/claude/pose1b_dark.png",
                 output_width=760, output_height=540)
print("ok")
