"""The official riscv-tests ISA tests (tests/riscv-tests submodule), each run in lockstep with
Spike on our minimal environment (tests/env/riscv_test.h)."""

import pytest

from programs import ROOT

ISA = ROOT / "tests" / "riscv-tests" / "isa"
INCLUDES = [ROOT / "tests" / "env", ISA / "macros" / "scalar"]

# Tests that cannot pass on this core, and why.
EXCLUDED = {
    "ma_data": "misaligned loads/stores: the core has no misaligned access support or trap "
               "handler yet",
}


def suite(name):
    tests = sorted(p for p in (ISA / name).glob("*.S"))
    return [pytest.param(p, id=p.stem,
                         marks=pytest.mark.skip(reason=EXCLUDED[p.stem]) if p.stem in EXCLUDED else ())
            for p in tests]


@pytest.mark.parametrize("src", suite("rv32ui"))
def test_rv32ui(run_lockstep, src):
    run_lockstep(src, INCLUDES, name=f"rv32ui-{src.stem}")


@pytest.mark.parametrize("src", suite("rv32um"))
def test_rv32um(run_lockstep, src):
    run_lockstep(src, INCLUDES, name=f"rv32um-{src.stem}")
