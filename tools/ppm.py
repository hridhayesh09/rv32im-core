"""Read the PPM frames the simulated VGA monitor saves, and write PNG images (no dependencies)."""

import struct
import zlib
from pathlib import Path


def read_ppm(path):
    """Returns (width, height, rows), rows = list of bytes, 3 bytes (RGB) per pixel."""
    data = Path(path).read_bytes()
    fields, pos = [], 0
    while len(fields) < 4:                       # "P6", width, height, maxval
        while data[pos:pos + 1].isspace():
            pos += 1
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    pos += 1                                     # one whitespace byte before the pixels
    width, height = int(fields[1]), int(fields[2])
    rows = [data[pos + y * width * 3: pos + (y + 1) * width * 3] for y in range(height)]
    return width, height, rows


def pixel(rows, x, y):
    return tuple(rows[y][3 * x: 3 * x + 3])


def write_png(path, width, height, rows):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    raw = b"".join(b"\x00" + row for row in rows)   # filter type 0 for every row
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    Path(path).write_bytes(png)


def ppm_to_png(ppm, png=None):
    width, height, rows = read_ppm(ppm)
    png = png or Path(ppm).with_suffix(".png")
    write_png(png, width, height, rows)
    return png
