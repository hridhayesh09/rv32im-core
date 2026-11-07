"""One-time: copy the int8 MNIST model and some test images from edge-ml-accelerator into
sw/mnist/mnist.npz, so this repo is self-contained.

    python3 tools/make_mnist_data.py <path to edge-ml-accelerator>

The model (784 -> 64 -> 10, int8, 97.67% test accuracy) was trained and quantized there
(host/mnist_train.py); nothing about it is changed here.
"""

import gzip
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
N_IMAGES = 200


def read_idx(path):
    with gzip.open(path, "rb") as f:
        data = f.read()
    ndim = data[3]
    dims = [int.from_bytes(data[4 + 4 * i: 8 + 4 * i], "big") for i in range(ndim)]
    return np.frombuffer(data, dtype=np.uint8, offset=4 + 4 * ndim).reshape(dims)


def main():
    host = Path(sys.argv[1]) / "host"
    q = np.load(host / "mnist_int8.npz")
    test_x = read_idx(host / "data" / "t10k-images-idx3-ubyte.gz").reshape(-1, 784)[:N_IMAGES]
    test_y = read_idx(host / "data" / "t10k-labels-idx1-ubyte.gz")[:N_IMAGES]
    out = ROOT / "sw" / "mnist" / "mnist.npz"
    out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        out,
        W1_q=q["W1_q"], b1_q=q["b1_q"].astype(np.int32),
        W2_q=q["W2_q"], b2_q=q["b2_q"].astype(np.int32),
        requant1_mult=q["requant1_mult"], requant1_shift=q["requant1_shift"],
        test_x=test_x, test_y=test_y,
    )
    print(f"wrote {out}: model + {N_IMAGES} test images ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
