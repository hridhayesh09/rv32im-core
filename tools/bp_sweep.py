"""Run the C test programs on the core (tb/tb_top.sv, 1-cycle memory, simulation) with several
branch predictor configurations, in lockstep with Spike, and print instructions, cycles and CPI.

    python tools/bp_sweep.py          (from the repository root, with the project venv active)
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests" / "core"))

import conftest  # noqa: E402
from test_c_programs import C_FLAGS, SW  # noqa: E402

CONFIGS = {
    "none":             dict(BP_MODE=0),
    "bimodal":          dict(BP_MODE=1, BTB_BITS=5, BHT_BITS=8, RAS_DEPTH=0),
    "gshare":           dict(BP_MODE=2, BTB_BITS=5, BHT_BITS=8, RAS_DEPTH=0),
    "gshare + RAS":     dict(BP_MODE=2, BTB_BITS=5, BHT_BITS=8, RAS_DEPTH=4),
}


def main():
    programs = sorted((SW / "programs").glob("*.c"))
    rows = []
    for label, params in CONFIGS.items():
        key = "sweep-" + label.replace(" + ", "-").replace(" ", "-")
        conftest.BP_CONFIGS[key] = params
        for src in programs:
            n, cycles = conftest.lockstep(src, [], name=f"{key}-{src.stem}", config=key,
                                          extra_sources=[SW / "crt0.S"], extra_flags=C_FLAGS)
            rows.append((label, src.stem, n, cycles))
    print(f"{'predictor':<14} {'program':<8} {'instructions':>12} {'cycles':>8} {'CPI':>6}")
    for label, prog, n, cycles in rows:
        print(f"{label:<14} {prog:<8} {n:>12} {cycles:>8} {cycles / n:>6.3f}")


if __name__ == "__main__":
    main()
