"""Debug fase 3 (hipótese única): o anti-aliasing do downscale explica a
divergência da máscara. Compara interpoladores do cv2 contra o PIL (referência
rembg), rodando o pipeline COMPLETO de cada lado e medindo contra o golden.

Também descarta troca de canais (RGB/BGR) no input Elixir.
Rodar: python/.venv/bin/python scripts/spikes/resampler_test.py
"""
import os

import cv2
import numpy as np
import onnxruntime as ort
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODEL = os.path.join(ROOT, "priv", "models", "u2net.onnx")
IMG = os.path.join(ROOT, "exemplos", "entrada", "casal.jpg")
GOLDEN = os.path.join(ROOT, "exemplos", "golden", "casal_mask.png")

MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)


def normalize(ary_u8):
    ary = ary_u8.astype(np.float32)
    ary = ary / max(ary.max(), 1e-6)
    tmp = np.zeros_like(ary)
    for c in range(3):
        tmp[:, :, c] = (ary[:, :, c] - MEAN[c]) / STD[c]
    return tmp.transpose((2, 0, 1))[np.newaxis, :].astype(np.float32)


def postprocess(d0, w, h, upscale):
    pred = d0[0, 0]
    pred = (pred - pred.min()) / (pred.max() - pred.min())
    m = (pred * 255).astype(np.uint8)
    if upscale == "pil":
        m = np.array(Image.fromarray(m, "L").resize((w, h), Image.LANCZOS))
    else:
        m = cv2.resize(m, (w, h), interpolation=cv2.INTER_LANCZOS4)
    return ((m > 30) * 255).astype(np.uint8)


def score(label, mask, golden):
    diff = np.abs(mask.astype(np.float32) - golden.astype(np.float32)) / 255.0
    mean = diff.mean() * 255
    frac = (diff > 5 / 255.0).mean() * 100
    verdict = "PASS" if (mean < 1.0 and frac <= 1.0) else "FAIL"
    print(f"{label:34s} diff médio {mean:7.4f}/255  >5/255: {frac:6.3f}%  {verdict}")


def main():
    sess = ort.InferenceSession(MODEL, providers=["CPUExecutionProvider"])
    in_name = sess.get_inputs()[0].name

    bgr = cv2.imread(IMG)
    rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
    h, w = rgb.shape[:2]
    golden = cv2.imread(GOLDEN, cv2.IMREAD_GRAYSCALE)

    pil_resized = np.array(Image.fromarray(rgb).resize((320, 320), Image.LANCZOS))

    # canal trocado? compara o input do Elixir com PIL em RGB e BGR
    ex_in = np.fromfile("/tmp/ex_input.bin", dtype="<f4").reshape(1, 3, 320, 320)
    pil_in = normalize(pil_resized)
    print(f"input ex vs PIL (RGB):      mean {np.abs(ex_in - pil_in).mean():.4f}")
    print(f"input ex vs PIL (canais inv): mean {np.abs(ex_in - pil_in[:, ::-1]).mean():.4f}")
    print()

    variants = [
        ("PIL LANCZOS (= rembg, sanity)", pil_resized, "pil"),
        ("cv2 INTER_AREA", cv2.resize(rgb, (320, 320), interpolation=cv2.INTER_AREA), "cv2"),
        ("cv2 INTER_LANCZOS4 (atual)", cv2.resize(rgb, (320, 320), interpolation=cv2.INTER_LANCZOS4), "cv2"),
        ("cv2 INTER_LINEAR", cv2.resize(rgb, (320, 320), interpolation=cv2.INTER_LINEAR), "cv2"),
    ]

    for label, resized, upscale in variants:
        d_in = np.abs(resized.astype(np.float32) - pil_resized.astype(np.float32)).mean()
        d0 = sess.run(None, {in_name: normalize(resized)})[0]
        mask = postprocess(d0, w, h, upscale)
        print(f"  [input u8 diff médio vs PIL: {d_in:6.2f}]")
        score(label, mask, golden)


if __name__ == "__main__":
    main()
