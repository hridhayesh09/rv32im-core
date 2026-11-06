"""The lockstep programs again, with random wait states on every data access (+random_stalls in
tb_top): a slow access freezes the whole pipeline, and every retired instruction must still
match Spike. This is what bus devices and SDRAM will do to the core in the SoC."""

import pytest

from programs import ROOT
from random_program import Generator
from programs import BUILD
from test_c_programs import C_FLAGS, SW
from test_riscv_tests import INCLUDES, suite

ASM = ROOT / "tests" / "asm"
STALLS = ["+random_stalls"]


@pytest.mark.parametrize("src", sorted(ASM.glob("*.S")), ids=lambda p: p.stem)
def test_asm(run_lockstep, src):
    run_lockstep(src, [ASM], name=f"ws-{src.stem}", plusargs=STALLS)


@pytest.mark.parametrize("src", suite("rv32ui") + suite("rv32um"))
def test_riscv_tests(run_lockstep, src):
    run_lockstep(src, INCLUDES, name=f"ws-{src.parent.name}-{src.stem}", plusargs=STALLS)


@pytest.mark.parametrize("src", sorted((SW / "programs").glob("*.c")), ids=lambda p: p.stem)
def test_c(run_lockstep, src):
    run_lockstep(src, [], name=f"ws-c-{src.stem}", plusargs=STALLS,
                 extra_sources=[SW / "crt0.S"], extra_flags=C_FLAGS)


@pytest.mark.parametrize("seed", range(10))
def test_random(run_lockstep, seed):
    src = BUILD / f"ws-random-{seed}.S"
    src.parent.mkdir(parents=True, exist_ok=True)
    src.write_text(Generator(1000 + seed).source())
    run_lockstep(src, [ASM], plusargs=STALLS)
