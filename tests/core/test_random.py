"""Random RV32I programs (random_program.py), each run in lockstep with Spike.

Seeds are fixed so a failure can be reproduced; RANDOM_PROGRAMS sets how many to run
(default 20, e.g. `RANDOM_PROGRAMS=500 make test` for a longer run).
"""

import os

import pytest

from programs import BUILD, ROOT
from random_program import Generator

COUNT = int(os.environ.get("RANDOM_PROGRAMS", "20"))


@pytest.mark.parametrize("seed", range(COUNT))
def test_random(run_lockstep, seed):
    src = BUILD / f"random-{seed}.S"
    src.parent.mkdir(parents=True, exist_ok=True)
    src.write_text(Generator(seed).source())
    run_lockstep(src, [ROOT / "tests" / "asm"])
