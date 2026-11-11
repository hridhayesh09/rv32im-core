"""Build the software for the board: the bootloader image for the boot ROM (used by the Quartus
build) and every program in sw/soc as a .bin to send with tools/upload.py.

    python3 tools/build_sw.py        (or: make sw)
"""

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests" / "soc"))
from soc_sim import SW, build_bootloader, build_coremark, build_program  # noqa: E402
from programs import build  # noqa: E402  (tests/core, put on the path by soc_sim)

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

    # CoreMark for the board: ITERATIONS=0 lets it pick a count that runs about 10 seconds.
    # coremark_ram.bin runs from on-chip RAM. coremark_sdram.bin is sent into SDRAM with --data
    # 0x40000000 and started by jump_to_sdram.bin (a 2-instruction program in RAM).
    for where in ("ram", "sdram"):
        binary = build_coremark(0, sdram=where == "sdram").with_suffix(".bin")
        shutil.copy(binary, OUT / f"coremark_{where}.bin")
        print(f"{OUT / f'coremark_{where}.bin'}  ({binary.stat().st_size} bytes)")
    _, stub, _ = build(SW / "boot" / "jump_to_sdram.S", [], name="ram-jump_to_sdram")
    shutil.copy(stub.with_suffix(".bin"), OUT / "jump_to_sdram.bin")
    print(f"{OUT / 'jump_to_sdram.bin'}  (starts a program in SDRAM)")


if __name__ == "__main__":
    main()
