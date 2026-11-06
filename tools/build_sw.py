"""Build the software for the board: the bootloader image for the boot ROM (used by the Quartus
build) and every program in sw/soc as a .bin to send with tools/upload.py.

    python3 tools/build_sw.py        (or: make sw)
"""

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests" / "soc"))
from soc_sim import SW, build_bootloader, build_program  # noqa: E402

OUT = ROOT / "build" / "sw"


ROM_WORDS = 2048   # 8 KB boot ROM


def write_mif(hexfile, mif, depth):
    """Intel memory initialization file, which the FPGA's block-RAM primitive loads."""
    words = [line.strip() for line in hexfile.read_text().splitlines() if line.strip()]
    if len(words) > depth:
        sys.exit(f"{hexfile} has {len(words)} words; the memory holds {depth}")
    lines = [f"WIDTH=32;", f"DEPTH={depth};", "ADDRESS_RADIX=HEX;", "DATA_RADIX=HEX;",
             "CONTENT BEGIN"]
    lines += [f"    {i:x} : {w};" for i, w in enumerate(words)]
    if len(words) < depth:
        lines.append(f"    [{len(words):x}..{depth - 1:x}] : 00000000;")
    lines.append("END;")
    mif.write_text("\n".join(lines) + "\n")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    rom = build_bootloader()
    shutil.copy(rom, OUT / "bootrom.hex")
    write_mif(rom, OUT / "bootrom.mif", ROM_WORDS)
    print(f"{OUT / 'bootrom.mif'}  (boot ROM image for Quartus)")
    for src in sorted((SW / "soc").glob("*.c")):
        binary = build_program(src).with_suffix(".bin")
        shutil.copy(binary, OUT / f"{src.stem}.bin")
        print(f"{OUT / (src.stem + '.bin')}  ({binary.stat().st_size} bytes, send with tools/upload.py)")


if __name__ == "__main__":
    main()
