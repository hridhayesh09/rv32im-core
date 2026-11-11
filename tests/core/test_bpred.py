"""Every lockstep test again with each branch predictor configuration (conftest.BP_CONFIGS): no
prediction, and tiny bimodal and gshare predictors whose tables alias all the time, with random
memory wait states. Predictions may only change timing: every retired instruction must still match
Spike."""

import pytest

from conftest import BP_CONFIGS
from programs import BUILD, ROOT
from random_program import Generator
from test_c_programs import C_FLAGS, SW
from test_riscv_tests import INCLUDES, suite

ASM = ROOT / "tests" / "asm"
STALLS = ["+random_stalls"]


@pytest.mark.parametrize("config", BP_CONFIGS)
@pytest.mark.parametrize("src", sorted(ASM.glob("*.S")), ids=lambda p: p.stem)
def test_asm(run_lockstep, config, src):
    run_lockstep(src, [ASM], name=f"bp-{config}-{src.stem}", plusargs=STALLS, config=config)


@pytest.mark.parametrize("config", BP_CONFIGS)
@pytest.mark.parametrize("src", suite("rv32ui") + suite("rv32um"))
def test_riscv_tests(run_lockstep, config, src):
    run_lockstep(src, INCLUDES, name=f"bp-{config}-{src.parent.name}-{src.stem}", plusargs=STALLS,
                 config=config)


@pytest.mark.parametrize("config", BP_CONFIGS)
@pytest.mark.parametrize("src", sorted((SW / "programs").glob("*.c")), ids=lambda p: p.stem)
def test_c(run_lockstep, config, src):
    run_lockstep(src, [], name=f"bp-{config}-c-{src.stem}", plusargs=STALLS, config=config,
                 extra_sources=[SW / "crt0.S"], extra_flags=C_FLAGS)


@pytest.mark.parametrize("config", BP_CONFIGS)
@pytest.mark.parametrize("seed", range(10))
def test_random(run_lockstep, config, seed):
    src = BUILD / f"bp-{config}-random-{seed}.S"
    src.parent.mkdir(parents=True, exist_ok=True)
    src.write_text(Generator(2000 + seed).source())
    run_lockstep(src, [ASM], plusargs=STALLS, config=config)
