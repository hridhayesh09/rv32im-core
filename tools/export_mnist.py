"""Pack the int8 MNIST model, test images and NumPy reference answers into one blob for SDRAM
(0x4000_0000), which sw/soc/mnist.c reads.

    python3 tools/export_mnist.py [n_images]      -> build/mnist/mnist_blob.bin and .hex

Blob layout (byte offsets in the header; every section starts on a 64-byte boundary):
  header   16 words: magic "MNST", n_images, then offsets of the sections below
  w1       W1 (784x64) as 49 x 4 tiles of 16x16 int8; tile (kt, nt) at (kt*4 + nt) * 256,
           byte r*16 + c = W1[16*kt + r][16*nt + c]   (the order the NPU loads a tile)
  w2       W2 (64x10, columns padded to 16) as 4 tiles, same layout
  b1, b2   int32 biases (b2 padded to 16)
  qlut     256 int8: pixel 0..255 -> quantized input 0..127
  images   n x 784 uint8 pixels
  labels   n bytes
  logits   n x 10 int32: the NumPy int8 model's outputs (the expected answer, bit for bit)
"""

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "mnist"
MAGIC = 0x54534E4D   # "MNST"


def quantize_input(images_u8):
    """Exactly edge-ml-accelerator's mnist_common.quantize_input."""
    x = images_u8.astype(np.float32) / 255.0
    return np.round(x * 127).astype(np.int8)


def reference(q, images_u8):
    """edge-ml-accelerator's int8_forward with NumPy integer matrix products."""
    x_q = quantize_input(images_u8)
    acc1 = x_q.astype(np.int64) @ q["W1_q"].astype(np.int64) + q["b1_q"]
    m, s = int(q["requant1_mult"]), int(q["requant1_shift"])
    h_q = np.clip((acc1 * m + (1 << (s - 1))) >> s, 0, 127).astype(np.int8)
    acc2 = h_q.astype(np.int64) @ q["W2_q"].astype(np.int64) + q["b2_q"]
    return acc2.astype(np.int32)


def tiles(w, k_tiles, n_tiles):
    out = bytearray()
    for kt in range(k_tiles):
        for nt in range(n_tiles):
            out += w[16 * kt: 16 * kt + 16, 16 * nt: 16 * nt + 16].astype(np.int8).tobytes()
    return bytes(out)


def build_blob(n_images):
    q = np.load(ROOT / "sw" / "mnist" / "mnist.npz")
    images = q["test_x"][:n_images]
    labels = q["test_y"][:n_images]
    w2 = np.zeros((64, 16), dtype=np.int8)
    w2[:, :10] = q["W2_q"]
    b2 = np.zeros(16, dtype=np.int32)
    b2[:10] = q["b2_q"]
    sections = [
        ("w1", tiles(q["W1_q"], 49, 4)),
        ("w2", tiles(w2, 4, 1)),
        ("b1", q["b1_q"].astype("<i4").tobytes()),
        ("b2", b2.astype("<i4").tobytes()),
        ("qlut", quantize_input(np.arange(256, dtype=np.uint8)).tobytes()),
        ("images", images.astype(np.uint8).tobytes()),
        ("labels", labels.astype(np.uint8).tobytes()),
        ("logits", reference(q, images).astype("<i4").tobytes()),
    ]
    body, offsets = bytearray(64), []
    for _, data in sections:
        offsets.append(len(body))
        body += data
        body += bytes(-len(body) % 64)
    header = np.array([MAGIC, n_images, *offsets] + [0] * (14 - len(offsets)), dtype="<u4")
    body[:64] = header.tobytes()
    return bytes(body), reference(q, images), labels


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    blob, logits, labels = build_blob(n)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "mnist_blob.bin").write_bytes(blob)
    words = np.frombuffer(blob + bytes(-len(blob) % 4), dtype="<u4")
    (OUT / "mnist_blob.hex").write_text("".join(f"{w:08x}\n" for w in words))
    accuracy = (logits.argmax(axis=1) == labels).mean()
    print(f"{OUT / 'mnist_blob.bin'}: {n} images, {len(blob)} bytes; "
          f"reference accuracy on these images {accuracy:.2%}")


if __name__ == "__main__":
    main()
