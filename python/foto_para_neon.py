"""Protótipo: foto real -> rotoscopia neon (pipeline determinístico, 100% local).

Etapas:
1. Segmenta a(s) pessoa(s) com rembg (u2net, saliência).
2. Mantém só o maior componente conectado da máscara (descarta transeuntes).
3. Traça bordas: contorno da silhueta + bordas internas (dobras de roupa) via Canny.
4. Compõe neon: linha + halos de blur coloridos sobre fundo preto.
"""
import cv2
import numpy as np
from rembg import remove, new_session

NEON_TEAL = (178, 196, 43)      # BGR de #2BC4B2
NEON_ORANGE = (92, 138, 255)    # BGR de #FF8A5C


def segment(img_bgr):
    session = new_session("u2net")
    rgba = remove(cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB), session=session)
    alpha = rgba[:, :, 3]
    mask = (alpha > 30).astype(np.uint8) * 255
    return mask


def largest_component(mask):
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    if n <= 1:
        return mask
    biggest = 1 + np.argmax(stats[1:, cv2.CC_STAT_AREA])
    return ((labels == biggest) * 255).astype(np.uint8)


def trace_edges(img_bgr, mask, canny_lo=50, canny_hi=120):
    gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    # CLAHE: revela dobras em tecidos escuros (preto sobre preto)
    gray = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8)).apply(gray)
    smooth = cv2.bilateralFilter(gray, 9, 60, 60)   # mata textura, preserva borda
    inner = cv2.Canny(smooth, canny_lo, canny_hi)
    inner = cv2.bitwise_and(inner, cv2.erode(mask, np.ones((5, 5), np.uint8)))
    silhouette = cv2.Canny(mask, 50, 150)
    edges = cv2.bitwise_or(inner, silhouette)
    # emenda micro-gaps do Canny antes de engrossar
    edges = cv2.morphologyEx(edges, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
    edges = cv2.dilate(edges, np.ones((2, 2), np.uint8), iterations=1)
    return edges


def neon_compose(edges, color, w, h):
    """Composição por MÁXIMO: a linha fica exatamente na cor do papel,
    os halos só preenchem ao redor — o matiz nunca estoura."""
    e = edges.astype(np.float32) / 255.0
    halo_big = cv2.GaussianBlur(e, (0, 0), 8) * 0.55
    halo_mid = cv2.GaussianBlur(e, (0, 0), 3) * 0.8
    intens = np.maximum(np.maximum(halo_big, halo_mid), e)
    canvas = np.zeros((h, w, 3), dtype=np.float32)
    for c in range(3):
        canvas[:, :, c] = intens * color[c]
    return np.clip(canvas, 0, 255).astype(np.uint8)


def photo_to_neon(in_path, out_path, color=NEON_TEAL,
                  canny_lo=60, canny_hi=140, debug_prefix=None):
    img = cv2.imread(in_path)
    h, w = img.shape[:2]
    mask = largest_component(segment(img))
    edges = trace_edges(img, mask, canny_lo, canny_hi)
    out = neon_compose(edges, color, w, h)
    cv2.imwrite(out_path, out)
    if debug_prefix:
        cv2.imwrite(f"{debug_prefix}_mask.png", mask)
        cv2.imwrite(f"{debug_prefix}_edges.png", edges)
    return out_path


def neon_duotone(edges, mask, color_left, color_right, w, h, blend_px=28):
    """Demo: cor por posição-x com transição suave na linha de contato.
    Em produção, troque por uma máscara de instância por pessoa."""
    _, xs = np.where(mask > 0)
    split = int(np.median(xs))
    xgrid = np.tile(np.arange(w, dtype=np.float32), (h, 1))
    wgt = 1 / (1 + np.exp(-(xgrid - split) / float(blend_px)))
    e = edges.astype(np.float32) / 255.0
    halo_big = cv2.GaussianBlur(e, (0, 0), 8) * 0.55
    halo_mid = cv2.GaussianBlur(e, (0, 0), 3) * 0.8
    intens = np.maximum(np.maximum(halo_big, halo_mid), e)
    canvas = np.zeros((h, w, 3), np.float32)
    for c in range(3):
        col = color_left[c] * (1 - wgt) + color_right[c] * wgt
        canvas[:, :, c] = intens * col
    return np.clip(canvas, 0, 255).astype(np.uint8)


if __name__ == "__main__":
    import sys
    entrada = sys.argv[1] if len(sys.argv) > 1 else "exemplos/entrada/casal.jpg"
    saida = sys.argv[2] if len(sys.argv) > 2 else "saida_neon.png"
    photo_to_neon(entrada, saida)
    print(f"ok: {saida}")
