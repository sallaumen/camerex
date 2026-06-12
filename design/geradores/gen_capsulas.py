"""Bonequinhos de forró v2 — rig de cápsulas com tronco em duas peças.

Modelo: cabeça, pescoço, BARRA DO OMBRO (sL-sR), coluna, BARRA DO QUADRIL (hL-hR),
membros em 2 segmentos com volume + mão/pé. Lado de trás em tom escuro sólido.
As duas barras são as 'linhas' do ombro e do quadril — dissociação visível.
"""
import cairosvg

BG = "#F2EBDD"
CONDUTOR = "#FF6B35"; CONDUTOR_SHADE = "#C84E1E"
CONDUZIDO = "#0F8A7D"; CONDUZIDO_SHADE = "#0A5F55"
COURO = "#7B4B28"
HEAD_R = 13

# larguras das cápsulas
W_SHOULDER = 16; W_HIP = 16; W_SPINE = 13; W_NECK = 8
W_UPARM = 10; W_FOREARM = 8.5; W_THIGH = 12; W_SHIN = 10; W_FOOT = 8
HAND_R = 5


def cap(p1, p2, color, w):
    (x1, y1), (x2, y2) = p1, p2
    return (f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" '
            f'stroke-width="{w}" stroke-linecap="round"/>')


def dot(p, color, r):
    return f'<circle cx="{p[0]}" cy="{p[1]}" r="{r}" fill="{color}"/>'


def arm(pts, color):
    s, e, w, h = pts
    return (cap(s, e, color, W_UPARM) + cap(e, w, color, W_FOREARM)
            + dot(h, color, HAND_R))


def leg(pts, color):
    h, k, a, t = pts
    return (cap(h, k, color, W_THIGH) + cap(k, a, color, W_SHIN)
            + cap(a, t, color, W_FOOT))


def hat(cx, cy):
    t = cy
    c = COURO
    return (f'<path d="M {cx-23} {t+6} Q {cx} {t-6} {cx+23} {t+6}" '
            f'stroke="{c}" stroke-width="5" fill="none" stroke-linecap="round"/>'
            f'<path d="M {cx-10} {t+4} Q {cx-8} {t-11} {cx} {t-13} '
            f'Q {cx+8} {t-11} {cx+10} {t+4} Z" fill="{c}"/>'
            f'<path d="M {cx-6} {t-11} Q {cx} {t-19} {cx+6} {t-11}" '
            f'stroke="{c}" stroke-width="3.5" fill="none" stroke-linecap="round"/>')


def figure(s, main, shade, with_hat=False):
    parts = []
    # membros de TRÁS primeiro (tom escuro sólido)
    if "arm_f" in s:
        parts.append(arm(s["arm_f"], shade))
    if "leg_f" in s:
        parts.append(leg(s["leg_f"], shade))
    # tronco em duas peças: barra do quadril, coluna, barra do ombro
    parts.append(cap(s["hL"], s["hR"], main, W_HIP))
    parts.append(cap(s["neck_base"], s["waist"], main, W_SPINE))
    parts.append(cap(s["sL"], s["sR"], main, W_SHOULDER))
    # membros da FRENTE (cor principal)
    parts.append(leg(s["leg_n"], main))
    parts.append(arm(s["arm_n"], main))
    # pescoço + cabeça
    hx, hy = s["head"]
    parts.append(cap((hx, hy + HEAD_R - 2), s["neck_base"], main, W_NECK))
    parts.append(dot(s["head"], main, HEAD_R))
    if with_hat:
        parts.append(hat(hx, hy - HEAD_R))
    return "".join(parts)


def scene(inner, w=380, h=270):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}">'
            f'<rect width="{w}" height="{h}" fill="{BG}"/>'
            f'<ellipse cx="{w/2}" cy="{h-18}" rx="{w*0.3}" ry="7" '
            f'fill="#2B2A26" opacity="0.07"/>{inner}</svg>')


# ============ POSE 1: ABRAÇO FECHADO ============
condutor_p1 = dict(
    head=(155, 74), neck_base=(152, 92),     # cabeça inclinada ao par
    sL=(139, 102), sR=(167, 98),
    waist=(150, 136), hL=(141, 152), hR=(159, 150),
    arm_n=[(167, 98), (193, 112), (216, 126), (221, 129)],   # mão na lateral da cintura
    arm_f=[(139, 102), (132, 126), (136, 148), (137, 153)],
    leg_n=[(159, 150), (170, 181), (175, 209), (189, 211)],  # passo curto, ponta a ponta
    leg_f=[(141, 152), (132, 182), (127, 210), (141, 212)],
)
conduzido_p1 = dict(
    head=(209, 72), neck_base=(212, 90),     # cabeça inclinada ao par
    sL=(198, 96), sR=(226, 100),
    waist=(214, 134), hL=(204, 150), hR=(222, 152),
    arm_n=[(198, 96), (183, 89), (170, 95), (166, 97)],
    arm_f=[(226, 100), (233, 124), (228, 146), (227, 151)],
    leg_n=[(204, 150), (208, 182), (206, 210), (192, 212)],  # pé encontra o do par
    leg_f=[(222, 152), (229, 182), (233, 210), (219, 212)],
)
pose1 = scene(figure(condutor_p1, CONDUTOR, CONDUTOR_SHADE, with_hat=True)
              + figure(conduzido_p1, CONDUZIDO, CONDUZIDO_SHADE))

# ============ POSE 2: DOIS PRA LÁ — quadril em dissociação ============
# Posição aberta, ambos deslocando o quadril pra esquerda da tela
# enquanto a linha do ombro permanece nivelada (dissociação).
condutor_p2 = dict(
    head=(118, 76), neck_base=(116, 94),
    sL=(102, 102), sR=(130, 102),            # linha do ombro NIVELADA
    waist=(109, 138),                        # cintura acompanha a pelve
    hL=(95, 149), hR=(123, 155),             # pelve deslocada à esq., lado do peso mais alto
    arm_n=[(130, 102), (152, 118), (170, 127), (174, 129)],  # pegada na altura da cintura
    arm_f=[(102, 102), (92, 124), (88, 144), (87, 149)],
    leg_n=[(123, 155), (134, 181), (142, 208), (155, 211)],  # perna livre estendida, pé apontado
    leg_f=[(95, 149), (93, 181), (92, 210), (106, 212)],     # perna de peso sob a pelve
)
conduzido_p2 = dict(
    head=(242, 76), neck_base=(244, 94),
    sL=(230, 102), sR=(258, 102),
    waist=(236, 138),
    hL=(222, 149), hR=(250, 155),            # pelve também à esquerda, mesma inclinação
    arm_n=[(230, 102), (206, 118), (180, 127), (177, 129)],
    arm_f=[(258, 102), (268, 124), (272, 144), (273, 149)],
    leg_n=[(250, 155), (260, 182), (266, 208), (252, 211)],
    leg_f=[(222, 149), (220, 181), (219, 210), (205, 212)],
)
# setinhas de movimento do quadril
sway = ('<path d="M 88 154 Q 78 161 88 168" stroke="#2B2A26" stroke-width="2" '
        'fill="none" opacity="0.35" stroke-linecap="round"/>'
        '<path d="M 214 154 Q 204 161 214 168" stroke="#2B2A26" stroke-width="2" '
        'fill="none" opacity="0.35" stroke-linecap="round"/>')
pose2 = scene(figure(condutor_p2, CONDUTOR, CONDUTOR_SHADE, with_hat=True)
              + figure(conduzido_p2, CONDUZIDO, CONDUZIDO_SHADE))


def build():
    return {"pose1": pose1, "pose2": pose2}


if __name__ == "__main__":
    for name, svg in build().items():
        with open(f"/home/claude/{name}b.svg", "w") as f:
            f.write(svg)
        cairosvg.svg2png(bytestring=svg.encode(), write_to=f"/home/claude/{name}b.png",
                         output_width=760, output_height=540)
    print("rendered")
