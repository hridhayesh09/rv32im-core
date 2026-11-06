"""The hand-written programs in tests/asm, each run in lockstep with Spike."""

import pytest

from programs import ROOT

ASM = ROOT / "tests" / "asm"


@pytest.mark.parametrize("src", sorted(ASM.glob("*.S")), ids=lambda p: p.stem)
def test_program(run_lockstep, src):
    run_lockstep(src, [ASM])
