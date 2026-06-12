"""Debug fase 1 (experimento cruzado): isola input vs runtime na divergência
da máscara. Compara:
  A: input PIL (fiel à rembg) + onnxruntime do venv  -> d0_py (referência)
  B: input Elixir (arquivo)   + onnxruntime do venv  -> d0_py_exin
  ex_d0: d0 do Ortex (arquivo, input Elixir)

Se A vs B for grande  -> o INPUT (resampler) é o culpado.
Se B vs ex_d0 for grande -> o RUNTIME é o culpado.
Rodar: python/.venv/bin/python scripts/spikes/cross_check.py
"""
import os

import numpy as np
import onnxruntime as ort
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODEL = os.path.join(ROOT, "priv", "models", "u2net.onnx")
IMG = os.path.join(ROOT, "exemplos", "entrada", "casal.jpg")

MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)


def pil_input():
    im = Image.open(IMG).convert("RGB").resize((320, 320), Image.LANCZOS)
    ary = np.array(im).astype(np.float32)
    ary = ary / max(ary.max(), 1e-6)
    tmp = np.zeros_like(ary)
    for c in range(3):
        tmp[:, :, c] = (ary[:, :, c] - MEAN[c]) / STD[c]
    return tmp.transpose((2, 0, 1))[np.newaxis, :].astype(np.float32)


def stats(label, a, b):
    d = np.abs(a - b)
    print(f"{label}: max={d.max():.6f} mean={d.mean():.6f}")


def main():
    print(f"onnxruntime do venv: {ort.__version__}")
    sess = ort.InferenceSession(MODEL, providers=["CPUExecutionProvider"])
    in_name = sess.get_inputs()[0].name

    py_in = pil_input()
    ex_in = np.fromfile("/tmp/ex_input.bin", dtype="<f4").reshape(1, 3, 320, 320)
    ex_d0 = np.fromfile("/tmp/ex_d0.bin", dtype="<f4").reshape(1, 1, 320, 320)

    stats("inputs (py vs ex)", py_in, ex_in)

    d0_py = sess.run(None, {in_name: py_in})[0]
    d0_py_exin = sess.run(None, {in_name: ex_in})[0]

    stats("A vs B: d0(py_in) vs d0(ex_in), mesmo runtime  [efeito do INPUT]",
          d0_py, d0_py_exin)
    stats("B vs ex: d0(ex_in) py-ORT vs Ortex             [efeito do RUNTIME]",
          d0_py_exin, ex_d0)
    stats("A vs ex: total (input + runtime)", d0_py, ex_d0)

    # onde o total diverge? fração de pixels com diff relevante pós min-max
    def norm(x):
        x = x[0, 0]
        return (x - x.min()) / (x.max() - x.min())

    flips = np.mean((norm(d0_py) > 30 / 255.0) != (norm(ex_d0) > 30 / 255.0))
    print(f"pixels 320x320 que flipam no limiar 30: {flips * 100:.3f}%")


if __name__ == "__main__":
    main()
