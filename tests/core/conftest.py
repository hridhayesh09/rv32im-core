"""Shared by the core-level tests: the core is built with Verilator once per test session,
and each program is then run on it in lockstep with Spike."""

import json
from pathlib import Path

import pytest

from programs import ROOT, build, spike_trace

HERE = Path(__file__).resolve().parent
RTL_SOURCES = ["rv_pkg.sv", "alu.sv", "regfile.sv", "decoder.sv", "muldiv.sv", "ram.sv", "core.sv"]


@pytest.fixture(scope="session")
def core_runner():
    from cocotb_tools.runner import get_runner
    runner = get_runner("verilator")
    runner.build(
        sources=[ROOT / "rtl" / f for f in RTL_SOURCES] + [ROOT / "tb" / "tb_top.sv"],
        hdl_toplevel="tb_top",
        build_dir=ROOT / "build" / "tb_top",
        build_args=["-Wall"],
        always=True,
    )
    return runner


@pytest.fixture
def run_lockstep(core_runner):
    """run_lockstep(src, includes, name): build the program, record Spike's trace, and run the
    `lockstep` cocotb test (in lockstep.py) against it."""
    def run(src, includes, name=None):
        elf, hexfile, tohost = build(src, includes, name)
        trace = elf.with_suffix(".trace.json")
        trace.write_text(json.dumps(spike_trace(elf, tohost)))
        core_runner.test(
            hdl_toplevel="tb_top",
            test_module="lockstep",
            test_dir=HERE,
            plusargs=[f"+program={hexfile}"],
            extra_env={"EXPECTED_TRACE": str(trace)},
            results_xml=str(elf.with_suffix(".result.xml")),
        )
    return run
