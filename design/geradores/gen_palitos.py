"""Gerador dos bonequinhos de forró — scratchpad de design.

Esqueleto data-driven: cada figura é um dict de articulações nomeadas.
Membros = polilinhas (ombro->cotovelo->mão, quadril->joelho->pé->ponta_do_pé).
Junções arredondadas via stroke-linejoin, SEM pontos explícitos.
"""
import cairosvg

BG = "#F2EBDD"
CONDUTOR = "#FF6B35"
CONDUZIDO = "#0F8A7D"
COURO = "#7B4B28"
W = 6            # espessura do traço
HEAD_R = 14


def path(points, color, w=W, opacity=1.0, curve=False):
    if curve:
        # tronco: leve curva quadrática
        (x0, y0), (cx, cy), (x1, y1) = points
        d = f"M {x0} {y0} Q {cx} {cy} {x1} {y1}"
    else:
        d = "M " + " L ".join(f"{x} {y}" for x, y in points)
    return (f'<path d="{d}" stroke="{color}" stroke-width="{w}" '
            f'opacity="{opacity}" fill="none" '
            f'stroke-linecap="round" stroke-linejoin="round"/>')


def head(cx, cy, color, r=HEAD_R):
    return f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{color}"/>'


def hat(cx, cy, color=None):
    """Chapéu de couro nordestino (sempre marrom couro), cy = topo da cabeça."""
    t = cy
    c = COURO
    parts = []
    # aba cruzando o topo da cabeça
    parts.append(f'<path d="M {cx-24} {t+6} Q {cx} {t-6} {cx+24} {t+6}" '
                 f'stroke="{c}" stroke-width="5" fill="none" stroke-linecap="round"/>')
    # copa baixa preenchida
    parts.append(f'<path d="M {cx-11} {t+4} Q {cx-9} {t-12} {cx} {t-14} '
                 f'Q {cx+9} {t-12} {cx+11} {t+4} Z" fill="{c}"/>')
    # meia-lua encostada na copa
    parts.append(f'<path d="M {cx-7} {t-12} Q {cx} {t-21} {cx+7} {t-12}" '
                 f'stroke="{c}" stroke-width="3.5" fill="none" stroke-linecap="round"/>')
    return "\n".join(parts)


def figure(j, color, with_hat=False):
    """j = dict de articulações. Braço de trás a 45% de opacidade."""
    parts = []
    # braço de trás primeiro (fica "atrás")
    if "elbow_b" in j:
        parts.append(path([j["shoulder"], j["elbow_b"], j["hand_b"]], color, opacity=0.45))
    # tronco
    parts.append(path([j["neck"], j["mid"], j["hip"]], color, curve=True))
    # braço da frente (curvo quando é abraço)
    if j.get("curve_f"):
        sx, sy = j["shoulder"]; ex, ey = j["elbow_f"]; hx2, hy2 = j["hand_f"]
        parts.append(f'<path d="M {sx} {sy} Q {ex} {ey} {hx2} {hy2}" stroke="{color}" '
                     f'stroke-width="{W}" fill="none" stroke-linecap="round"/>')
    else:
        parts.append(path([j["shoulder"], j["elbow_f"], j["hand_f"]], color))
    # braço extra (ex: giro com dois braços visíveis)
    if "elbow_x" in j:
        parts.append(path([j["shoulder"], j["elbow_x"], j["hand_x"]], color))
    # pernas (com ponta do pé)
    parts.append(path([j["hip"], j["knee_a"], j["foot_a"], j["toe_a"]], color))
    parts.append(path([j["hip"], j["knee_b"], j["foot_b"], j["toe_b"]], color))
    # cabeça por cima
    hx, hy = j["head"]
    parts.append(head(hx, hy, color))
    if with_hat:
        parts.append(hat(hx, hy - HEAD_R, color))
    return "\n".join(parts)


def scene(figures_svg, w=360, h=260, shadow=True):
    sh = (f'<ellipse cx="{w/2}" cy="{h-20}" rx="{w*0.27}" ry="7" '
          f'fill="#2B2A26" opacity="0.07"/>') if shadow else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}">'
            f'<rect width="{w}" height="{h}" fill="{BG}"/>{sh}{figures_svg}</svg>')


# ---------------- POSE 1: abraço fechado (coladinho) ----------------
condutor_p1 = dict(
    head=(158, 84),
    neck=(158, 98), mid=(154, 134), hip=(148, 168),
    shoulder=(157, 112),
    elbow_f=(192, 124), hand_f=(216, 146), curve_f=True,     # abraçando as costas do par
    elbow_b=(144, 138), hand_b=(141, 159),     # braço de trás, mais baixo, na cintura
    knee_a=(138, 194), foot_a=(132, 220), toe_a=(143, 222),
    knee_b=(166, 192), foot_b=(168, 217), toe_b=(179, 217),
)
conduzido_p1 = dict(
    head=(202, 82),
    neck=(202, 96), mid=(206, 134), hip=(212, 168),
    shoulder=(203, 110),
    elbow_f=(180, 100), hand_f=(160, 109),     # mão no ombro do condutor
    knee_a=(203, 195), foot_a=(199, 222), toe_a=(188, 222),
    knee_b=(223, 194), foot_b=(228, 220), toe_b=(217, 222),
)

pose1 = scene(figure(condutor_p1, CONDUTOR, with_hat=True) +
              figure(conduzido_p1, CONDUZIDO))

# ---------------- POSE 2: giro ----------------
condutor_p2 = dict(
    head=(126, 92),
    neck=(126, 106), mid=(127, 140), hip=(129, 174),
    shoulder=(127, 120),
    elbow_f=(157, 77), hand_f=(185, 55),       # braço erguido conduzindo
    elbow_b=(116, 144), hand_b=(123, 163),
    knee_a=(120, 198), foot_a=(114, 222), toe_a=(126, 224),
    knee_b=(144, 196), foot_b=(151, 220), toe_b=(163, 220),
)
conduzido_p2 = dict(
    head=(216, 92),
    neck=(216, 106), mid=(219, 140), hip=(213, 174),
    shoulder=(215, 120),
    elbow_f=(196, 90), hand_f=(189, 57),       # mão encontra a do condutor
    elbow_x=(243, 130), hand_x=(262, 118),     # braço aberto no giro
    knee_a=(214, 198), foot_a=(212, 222), toe_a=(223, 222),
    knee_b=(227, 195), foot_b=(218, 214), toe_b=(207, 213),
)

pose2 = scene(figure(condutor_p2, CONDUTOR, with_hat=True) +
              figure(conduzido_p2, CONDUZIDO))

def build():
    return {"pose1": pose1, "pose2": pose2}


if __name__ == "__main__":
  for name, svg in [("pose1", pose1), ("pose2", pose2)]:
      with open(f"/home/claude/{name}.svg", "w") as f:
          f.write(svg)
      cairosvg.svg2png(bytestring=svg.encode(), write_to=f"/home/claude/{name}.png",
                       output_width=720, output_height=520)
  print("rendered")
