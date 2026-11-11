"""CoreMark in simulation (the whole SoC with the SDRAM model, tb/tb_soc.sv) for several branch
predictor and cache configurations: the measured side of the tradeoff table.

    python tools/coremark_sweep.py [ITERATIONS [FILTER]]   (default 2 iterations, all configs;
                                                            FILTER: only names containing it)

Each configuration builds its own Verilator model (build/tb_soc-<name>). CoreMark runs from SDRAM
through the caches, except the "ram" rows, which run from the 1-cycle on-chip RAM.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests" / "soc"))

from soc_sim import SW, build_bootrom, build_coremark, build_soc  # noqa: E402

DEFAULT = dict(ICACHE_SIZE=4096, ICACHE_WAYS=1, DCACHE_SIZE=4096, DCACHE_WAYS=1,
               BP_MODE=2, BTB_BITS=5, BHT_BITS=8, RAS_DEPTH=4)

# name: (where the program runs, changes from DEFAULT)
CONFIGS = {
    "ram-nobp":       ("ram",   dict(BP_MODE=0)),
    "ram-bimodal":    ("ram",   dict(BP_MODE=1, RAS_DEPTH=0)),
    "ram-gshare":     ("ram",   dict(RAS_DEPTH=0)),
    "ram-gshare-ras": ("ram",   dict()),
    "ram-btb16":      ("ram",   dict(BTB_BITS=4)),
    "ram-btb64":      ("ram",   dict(BTB_BITS=6)),
    "ram-bht1k":      ("ram",   dict(BHT_BITS=10)),
    "sdram-1k-dm":    ("sdram", dict(ICACHE_SIZE=1024, DCACHE_SIZE=1024)),
    "sdram-2k-dm":    ("sdram", dict(ICACHE_SIZE=2048, DCACHE_SIZE=2048)),
    "sdram-4k-dm":    ("sdram", dict()),
    "sdram-8k-dm":    ("sdram", dict(ICACHE_SIZE=8192, DCACHE_SIZE=8192)),
    "sdram-1k-2way":  ("sdram", dict(ICACHE_SIZE=1024, DCACHE_SIZE=1024, ICACHE_WAYS=2, DCACHE_WAYS=2)),
    "sdram-4k-2way":  ("sdram", dict(ICACHE_WAYS=2, DCACHE_WAYS=2)),
}


def main():
    iterations = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    only = sys.argv[2] if len(sys.argv) > 2 else ""
    rows = []
    for name, (where, changes) in CONFIGS.items():
        if only not in name:
            continue
        params = {**DEFAULT, **changes}
        runner = build_soc(params, tag=f"-{name}")
        bootrom = build_bootrom(SW / "boot" / ("jump_to_sdram.S" if where == "sdram" else "jump_to_ram.S"))
        program = build_coremark(iterations, sdram=where == "sdram")
        log = ROOT / "build" / f"coremark-sweep-{name}.log"
        runner.test(hdl_toplevel="tb_soc", test_module="test_soc", testcase="coremark",
                    test_dir=ROOT / "tests" / "soc",
                    plusargs=[f"+bootrom={bootrom}",
                              f"+sdram_init={program}" if where == "sdram" else f"+program={program}"],
                    results_xml=str(ROOT / "build" / f"coremark-sweep-{name}.xml"), log_file=log)
        m = re.search(r"CoreMark/MHz ([\d.]+), CPI ([\d.]+), mispredicts (\d+)/(\d+)", log.read_text())
        if not m:
            raise RuntimeError(f"{name}: no result in {log}")
        rows.append((name, *m.groups()))
    print(f"{'config':<16} {'CoreMark/MHz':>12} {'CPI':>6} {'mispredicts':>16}")
    for name, cm, cpi, misp, br in rows:
        print(f"{name:<16} {cm:>12} {cpi:>6} {misp:>7}/{br:<7} {100 * int(misp) / int(br):5.1f} %")


if __name__ == "__main__":
    main()
