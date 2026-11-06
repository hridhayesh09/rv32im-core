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


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    rom = build_bootloader()
    shutil.copy(rom, OUT / "bootrom.hex")
    print(f"{OUT / 'bootrom.hex'}  (boot ROM image for Quartus)")
    for src in sorted((SW / "soc").glob("*.c")):
        binary = build_program(src).with_suffix(".bin")
        shutil.copy(binary, OUT / f"{src.stem}.bin")
        print(f"{OUT / (src.stem + '.bin')}  ({binary.stat().st_size} bytes, send with tools/upload.py)")


if __name__ == "__main__":
    main()
