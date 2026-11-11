"""Build Doom (third_party/doomgeneric) for rv32im-core with picolibc.

    python3 tools/build_doom.py          -> build/doom/doom.elf, build/sw/doom.bin

Runs from SDRAM (CPU-only build with caches and the 8-bit VGA mode): code at 0x4000_0000, data,
heap and stack after it, the WAD at 0x4200_0000. Start it with
    python tools/upload.py COM8 build/sw/jump_to_sdram.bin --baud 2000000 \\
        --data 0x40000000 build/sw/doom.bin --data 0x42000000 <file.wad>

picolibc comes from the Ubuntu package picolibc-riscv64-unknown-elf, either installed or unpacked
into ~/tools/picolibc (PICOLIBC=<dir> to use another place).
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DG = ROOT / "third_party" / "doomgeneric" / "doomgeneric"
OUT = ROOT / "build" / "doom"

ARCH = ["-march=rv32im_zicsr_zifencei", "-mabi=ilp32"]
CFLAGS = ["-O2", "-g", "-ffunction-sections", "-fdata-sections", "-DCMAP256",
          "-DDOOMGENERIC_RESX=320", "-DDOOMGENERIC_RESY=200", "-DNORMALUNIX",
          "-D_DEFAULT_SOURCE", "-Wno-unused-result", "-Wno-format-truncation",
          "-Wno-stringop-truncation", "-Wno-dangling-pointer", "-Wno-unused-but-set-variable"]
# Memory map for picolibc.ld (code and constants in "flash", the rest in "ram"; both SDRAM).
LAYOUT = {"__flash": 0x40000000, "__flash_size": 0x00400000,
          "__ram": 0x40400000, "__ram_size": 0x01C00000, "__stack_size": 0x00010000}


def picolibc():
    for base in [os.environ.get("PICOLIBC"), str(Path.home() / "tools" / "picolibc"), "/"]:
        if base:
            p = Path(base) / "usr" / "lib" / "picolibc" / "riscv64-unknown-elf"
            if (p / "lib" / "picolibc.ld").exists():
                return p
    sys.exit("picolibc not found: install picolibc-riscv64-unknown-elf or unpack it into "
             "~/tools/picolibc")


def doom_sources():
    make = (DG / "Makefile").read_text()
    objs = re.search(r"^SRC_DOOM\s*=\s*(.*)$", make, re.M).group(1).split()
    return [DG / o.replace(".o", ".c") for o in objs if not o.startswith("doomgeneric_")]


def main():
    pico = picolibc()
    lib = pico / "lib" / "release" / "rv32im" / "ilp32"
    OUT.mkdir(parents=True, exist_ok=True)
    gcc = "riscv64-unknown-elf-gcc"
    includes = ["-nostdinc", "-isystem", str(pico / "include"),
                "-isystem", subprocess.check_output([gcc, "-print-file-name=include"], text=True).strip(),
                "-I", str(DG), "-I", str(ROOT / "sw" / "doom")]
    sources = doom_sources() + sorted((ROOT / "sw" / "doom").glob("*.c"))
    objs = []
    for src in sources:
        obj = OUT / (src.stem + ".o")
        if not obj.exists() or obj.stat().st_mtime < src.stat().st_mtime:
            subprocess.run([gcc, *ARCH, *CFLAGS, *includes, "-c", str(src), "-o", str(obj)],
                           check=True)
        objs.append(obj)
    elf = OUT / "doom.elf"
    defsyms = [f"-Wl,--defsym={k}={v:#x}" for k, v in LAYOUT.items()]
    subprocess.run([gcc, *ARCH, "-nostdlib", "-nostartfiles", "-T", str(pico / "lib" / "picolibc.ld"),
                    *defsyms, "-Wl,--gc-sections", "-Wl,--no-warn-rwx-segments",
                    f"-Wl,-Map,{OUT / 'doom.map'}",
                    str(lib / "crt0.o"), *map(str, objs), "-o", str(elf),
                    "-L", str(lib), "-lc", "-lm", "-lgcc", "-lc"], check=True)
    binary = OUT / "doom.bin"
    subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", str(elf), str(binary)], check=True)
    (ROOT / "build" / "sw").mkdir(parents=True, exist_ok=True)
    shutil.copy(binary, ROOT / "build" / "sw" / "doom.bin")
    size = subprocess.check_output(["riscv64-unknown-elf-size", str(elf)], text=True)
    print(size.strip())
    print(f"{ROOT / 'build' / 'sw' / 'doom.bin'}: {binary.stat().st_size} bytes")


if __name__ == "__main__":
    main()
