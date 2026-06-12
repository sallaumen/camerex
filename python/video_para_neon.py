"""Vídeo real -> rotoscopia neon, quadro a quadro, 100% local.

Além do pipeline de foto, vídeo exige:
- sessão de segmentação reutilizada (performance);
- suavização temporal da máscara (EMA) pra silhueta não tremer;
- rastro de luz: o traço dos frames anteriores decai devagar (light painting);
- split do duotone estabilizado por EMA pra cor não pular entre frames.
"""
import os
import subprocess
import cv2
import numpy as np
from rembg import remove, new_session

from foto_para_neon import trace_edges, largest_component, NEON_TEAL, NEON_ORANGE


def consistent_component(mask, prev_bin):
    """Escolhe o componente com maior sobreposição com a máscara anterior
    (evita o sujeito 'pular' para outra pessoa); sem anterior, usa o maior."""
    if prev_bin is None:
        return largest_component(mask)
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    if n <= 1:
        return mask
    best, best_score = 1, -1.0
    prev = prev_bin > 0
    for i in range(1, n):
        comp = labels == i
        overlap = np.logical_and(comp, prev).sum()
        score = overlap + 1e-4 * stats[i, cv2.CC_STAT_AREA]
        if score > best_score:
            best, best_score = i, score
    return ((labels == best) * 255).astype(np.uint8)


def video_para_neon(in_path, out_path,
                    color_left=NEON_ORANGE, color_right=NEON_TEAL,
                    duotone=True,
                    trail_decay=0.80,      # 0 = sem rastro; ~0.8 = rastro curto
                    mask_ema=0.45,         # peso do frame anterior na máscara
                    fps_out=15,
                    work_width=640,
                    model="u2net"):       # u2netp: leve e rápido p/ vídeo
    session = new_session(model)
    cap = cv2.VideoCapture(in_path)
    tmp_dir = "/tmp/neon_frames"
    os.makedirs(tmp_dir, exist_ok=True)
    for f in os.listdir(tmp_dir):
        os.remove(os.path.join(tmp_dir, f))

    mask_f = None
    trail = None
    split_ema = None
    idx = 0

    while True:
        ok, frame = cap.read()
        if not ok:
            break
        h0, w0 = frame.shape[:2]
        scale = work_width / w0
        th = int(h0 * scale) // 2 * 2          # altura par (exigência do H.264)
        frame = cv2.resize(frame, (work_width, th),
                           interpolation=cv2.INTER_CUBIC)
        h, w = frame.shape[:2]

        # segmentação (sessão reutilizada); clareia sombras só se a cena for escura
        seg_in = frame
        if frame.mean() < 70:
            seg_in = cv2.convertScaleAbs(frame, alpha=1.4, beta=18)
        rgba = remove(cv2.cvtColor(seg_in, cv2.COLOR_BGR2RGB), session=session)
        prev_bin = None if mask_f is None else ((mask_f > 0.45) * 255).astype(np.uint8)
        m = consistent_component(((rgba[:, :, 3] > 30) * 255).astype(np.uint8), prev_bin)
        m = m.astype(np.float32) / 255.0

        # suavização temporal da máscara (anti-flicker da silhueta)
        mask_f = m if mask_f is None else mask_ema * mask_f + (1 - mask_ema) * m
        mask_bin = ((mask_f > 0.45) * 255).astype(np.uint8)

        edges = trace_edges(frame, mask_bin).astype(np.float32) / 255.0

        # rastro de luz: traço atual + traços anteriores decaindo
        trail = edges if trail is None else np.maximum(edges, trail * trail_decay)

        # intensidade neon por máximo (matiz exato na linha)
        halo_big = cv2.GaussianBlur(trail, (0, 0), 8) * 0.55
        halo_mid = cv2.GaussianBlur(trail, (0, 0), 3) * 0.8
        intens = np.maximum(np.maximum(halo_big, halo_mid), edges)

        canvas = np.zeros((h, w, 3), np.float32)
        if duotone:
            xs = np.where(mask_bin > 0)[1]
            split_now = float(np.median(xs)) if xs.size else w / 2
            split_ema = (split_now if split_ema is None
                         else 0.9 * split_ema + 0.1 * split_now)
            xgrid = np.tile(np.arange(w, dtype=np.float32), (h, 1))
            wgt = 1 / (1 + np.exp(-(xgrid - split_ema) / 24.0))
            for c in range(3):
                col = color_left[c] * (1 - wgt) + color_right[c] * wgt
                canvas[:, :, c] = intens * col
        else:
            for c in range(3):
                canvas[:, :, c] = intens * color_right[c]

        out = np.clip(canvas, 0, 255).astype(np.uint8)
        cv2.imwrite(f"{tmp_dir}/f_{idx:05d}.png", out)
        idx += 1

    cap.release()

    # encode final em H.264 (compatível com navegador/celular)
    subprocess.run([
        "ffmpeg", "-y", "-v", "error",
        "-framerate", str(fps_out),
        "-i", f"{tmp_dir}/f_%05d.png",
        "-c:v", "libx264", "-pix_fmt", "yuv420p",
        "-crf", "20",
        out_path,
    ], check=True)
    return idx


if __name__ == "__main__":
    import sys
    entrada = sys.argv[1] if len(sys.argv) > 1 else "exemplos/entrada/clip.mp4"
    saida = sys.argv[2] if len(sys.argv) > 2 else "saida_neon.mp4"
    n = video_para_neon(entrada, saida, duotone=False, trail_decay=0.6)
    print(f"ok: {n} frames -> {saida}")
