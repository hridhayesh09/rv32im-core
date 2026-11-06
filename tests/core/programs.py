"""Building test programs and getting Spike's reference trace for them."""

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build" / "programs"
BASE_ADDR = 0x80000000

CFLAGS = ["-march=rv32im", "-mabi=ilp32", "-nostdlib", "-nostartfiles", "-mno-relax",
          "-Wl,--no-warn-rwx-segments", "-T", str(ROOT / "sw" / "link.ld")]


def build(src, includes, name=None):
    """Assemble/compile one program. Returns (elf path, hex path, tohost address)."""
    BUILD.mkdir(parents=True, exist_ok=True)
    name = name or src.stem
    elf = BUILD / f"{name}.elf"
    include_flags = [flag for inc in includes for flag in ("-I", str(inc))]
    subprocess.run(["riscv64-unknown-elf-gcc", *CFLAGS, *include_flags, "-o", str(elf), str(src)],
                   check=True)

    binary = BUILD / f"{name}.bin"
    subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", str(elf), str(binary)], check=True)
    image = binary.read_bytes()
    image += bytes(-len(image) % 4)
    hexfile = BUILD / f"{name}.hex"
    hexfile.write_text("".join(f"{int.from_bytes(image[i:i + 4], 'little'):08x}\n"
                               for i in range(0, len(image), 4)))

    symbols = subprocess.run(["riscv64-unknown-elf-nm", str(elf)], check=True,
                             capture_output=True, text=True).stdout
    tohost = next(int(line.split()[0], 16) for line in symbols.splitlines()
                  if line.endswith(" tohost"))
    return elf, hexfile, tohost


_LINE = re.compile(r"core\s+\d+: \d+ 0x([0-9a-f]+) \(0x([0-9a-f]+)\)(.*)")
_REG = re.compile(r"\sx(\d+)\s+0x([0-9a-f]+)")   # \s: don't match the "x" inside "0x..."
_MEM = re.compile(r"mem 0x([0-9a-f]+)(?: 0x([0-9a-f]+))?")


def spike_trace(elf, tohost, isa="rv32im"):
    """Run the program on Spike and return its retired instructions, up to and including
    the store to tohost. Each entry: pc, insn, rd, rd_wdata, mem (None, "load" or "store"),
    mem_addr, store_data, store_bytes."""
    try:
        proc = subprocess.run(["spike", f"--isa={isa}", "--log-commits", str(elf)],
                              capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{elf.name}: Spike still running after 60 s; "
                           "the program probably never writes tohost") from None
    trace = []
    for line in proc.stderr.splitlines():
        match = _LINE.match(line)
        if not match:
            continue
        pc, insn, rest = int(match[1], 16), int(match[2], 16), match[3]
        if pc < BASE_ADDR:
            continue  # Spike's boot ROM
        entry = {"pc": pc, "insn": insn, "rd": 0, "rd_wdata": 0,
                 "mem": None, "mem_addr": 0, "store_data": 0, "store_bytes": 0}
        if reg := _REG.search(rest):
            entry["rd"], entry["rd_wdata"] = int(reg[1]), int(reg[2], 16)
        if mem := _MEM.search(rest):
            entry["mem_addr"] = int(mem[1], 16)
            if mem[2] is None:
                entry["mem"] = "load"
            else:
                entry["mem"] = "store"
                entry["store_data"] = int(mem[2], 16)
                entry["store_bytes"] = len(mem[2]) // 2
        trace.append(entry)
        if entry["mem"] == "store" and entry["mem_addr"] == tohost:
            return trace
    raise RuntimeError(f"{elf.name}: Spike never wrote tohost")
