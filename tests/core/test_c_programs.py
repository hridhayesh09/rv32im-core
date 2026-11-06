"""C programs in sw/programs, compiled with GCC (-O2) and linked with sw/crt0.S, each run in
lockstep with Spike. main returning 0 means the program's own checks passed."""

import pytest

from programs import ROOT

SW = ROOT / "sw"
C_FLAGS = ["-O2", "-ffreestanding", "-fno-builtin", "-Wall", "-Werror"]


@pytest.mark.parametrize("src", sorted((SW / "programs").glob("*.c")), ids=lambda p: p.stem)
def test_c_program(run_lockstep, src):
    instructions, cycles = run_lockstep(src, [], name=f"c-{src.stem}",
                                        extra_sources=[SW / "crt0.S"], extra_flags=C_FLAGS)
    print(f"{src.stem}: {instructions} instructions, {cycles} cycles, CPI {cycles / instructions:.3f}")
