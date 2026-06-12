"""Gera golden files para os testes de paridade Elixir x Python.

Roda UMA vez e os PNGs em exemplos/golden/ são commitados. Determinístico:
mesmas entradas -> mesmos bytes. Parâmetros fixados nos valores do CONTRATO
do port Elixir (não nos defaults do protótipo):
  - canny 60/140  == detail 0.5 (contrato §4 trace_edges)
  - blend_px = 24 (contrato §4 duotone_weights; default do protótipo era 28)
"""
import os

import cv2

from foto_para_neon import (NEON_ORANGE, NEON_TEAL, largest_component,
                            neon_compose, neon_duotone, segment, trace_edges)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
IN_PATH = os.path.join(ROOT, "exemplos", "entrada", "casal.jpg")
OUT_DIR = os.path.join(ROOT, "exemplos", "golden")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    img = cv2.imread(IN_PATH)
    assert img is not None, f"nao achei {IN_PATH}"
    h, w = img.shape[:2]

    mask = largest_component(segment(img))
    edges = trace_edges(img, mask, canny_lo=60, canny_hi=140)
    teal = neon_compose(edges, NEON_TEAL, w, h)
    duo = neon_duotone(edges, mask, NEON_ORANGE, NEON_TEAL, w, h, blend_px=24)

    outputs = [
        ("casal_mask.png", mask),
        ("casal_edges.png", edges),
        ("casal_neon_teal.png", teal),
        ("casal_neon_duotone.png", duo),
    ]
    for name, image in outputs:
        path = os.path.join(OUT_DIR, name)
        ok = cv2.imwrite(path, image)
        assert ok, f"falha ao gravar {path}"
        print(f"ok: {os.path.relpath(path, ROOT)}")


if __name__ == "__main__":
    main()
