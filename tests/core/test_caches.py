"""Every lockstep test again, with the program reached only through the caches (tb/tb_cached.sv):
tiny direct-mapped and 2-way caches (256 bytes each, so lines are evicted and dirty lines written
back all the time), slow memory, and random memory latency. Every retired instruction must still
match Spike."""

import pytest

from conftest import CACHE_CONFIGS
from programs import BUILD, ROOT
from random_program import Generator
from test_c_programs import C_FLAGS, SW
from test_riscv_tests import INCLUDES, suite

ASM = ROOT / "tests" / "asm"
STALLS = ["+random_stalls"]


@pytest.mark.parametrize("config", CACHE_CONFIGS)
@pytest.mark.parametrize("src", sorted(ASM.glob("*.S")), ids=lambda p: p.stem)
def test_asm(run_lockstep, config, src):
    run_lockstep(src, [ASM], name=f"cached-{src.stem}", plusargs=STALLS, config=config)


@pytest.mark.parametrize("config", CACHE_CONFIGS)
@pytest.mark.parametrize("src", suite("rv32ui") + suite("rv32um"))
def test_riscv_tests(run_lockstep, config, src):
    run_lockstep(src, INCLUDES, name=f"cached-{src.parent.name}-{src.stem}", plusargs=STALLS,
                 config=config)


@pytest.mark.parametrize("config", CACHE_CONFIGS)
@pytest.mark.parametrize("src", sorted((SW / "programs").glob("*.c")), ids=lambda p: p.stem)
def test_c(run_lockstep, config, src):
    run_lockstep(src, [], name=f"cached-c-{src.stem}", plusargs=STALLS, config=config,
                 extra_sources=[SW / "crt0.S"], extra_flags=C_FLAGS)


@pytest.mark.parametrize("config", CACHE_CONFIGS)
@pytest.mark.parametrize("seed", range(10))
def test_random(run_lockstep, config, seed):
    src = BUILD / f"cached-random-{seed}.S"
    src.parent.mkdir(parents=True, exist_ok=True)
    src.write_text(Generator(2000 + seed).source())
    run_lockstep(src, [ASM], plusargs=STALLS, config=config)
