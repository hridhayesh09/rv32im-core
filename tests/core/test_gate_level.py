"""Gate-level simulation of the ASIC netlist (Stage 6): the final Sky130 netlist from OpenLane
(asic/runs/<latest>/final/nl/rv32im_asic.nl.v) runs the riscv-tests in Icarus Verilog with the
PDK's standard-cell models, in lockstep with Spike (tb/tb_asic_gl.sv, tests/core/lockstep.py).

Skipped until the ASIC flow has produced a netlist (asic/run_flow.sh). Needs iverilog and the
Sky130 PDK (PDK_ROOT, default ~/.volare or ~/.ciel, where OpenLane 2 puts it).
"""

import json
import os
import re
import shutil
from pathlib import Path

import pytest

from programs import ROOT, build, spike_trace
from test_riscv_tests import INCLUDES, suite

HERE = Path(__file__).resolve().parent
RUNS = ROOT / "asic" / "runs"


def latest_netlist():
    if not RUNS.exists():
        return None
    nets = sorted(RUNS.glob("*/final/nl/rv32im_asic.nl.v"), key=lambda p: p.stat().st_mtime)
    return nets[-1] if nets else None


def cell_models():
    roots = [os.environ.get("PDK_ROOT"), Path.home() / ".volare", Path.home() / ".ciel"]
    for root in filter(None, roots):
        for lib in sorted(Path(root).glob("**/sky130A/libs.ref/sky130_fd_sc_hd/verilog")):
            if (lib / "primitives.v").exists() and (lib / "sky130_fd_sc_hd.v").exists():
                return [lib / "primitives.v", lib / "sky130_fd_sc_hd.v"]
    return None


NETLIST, MODELS = latest_netlist(), cell_models()
pytestmark = pytest.mark.skipif(
    NETLIST is None or MODELS is None or shutil.which("iverilog") is None,
    reason="needs an ASIC netlist (asic/run_flow.sh), the Sky130 PDK and iverilog")

_runner = None


def gl_runner():
    global _runner
    if _runner is None:
        from cocotb_tools.runner import get_runner
        _runner = get_runner("icarus")
        _runner.build(
            sources=[*MODELS, NETLIST, ROOT / "tb" / "line_mem.sv", ROOT / "tb" / "tb_asic_gl.sv"],
            hdl_toplevel="tb_asic_gl", build_dir=ROOT / "build" / "tb_asic_gl",
            defines={"FUNCTIONAL": 1, "UNIT_DELAY": "#1"},   # cell models without timing
            build_args=["-g2012"], always=True)
    return _runner


@pytest.mark.parametrize("src", suite("rv32ui") + suite("rv32um"))
def test_riscv_tests_gate_level(src):
    elf, hexfile, tohost = build(src, INCLUDES, name=f"gl-{src.parent.name}-{src.stem}")
    trace = elf.with_suffix(".trace.json")
    trace.write_text(json.dumps(spike_trace(elf, tohost)))
    log = elf.with_name(elf.stem + ".log")
    gl_runner().test(
        hdl_toplevel="tb_asic_gl", test_module="lockstep", test_dir=HERE,
        plusargs=[f"+program={hexfile}"], extra_env={"EXPECTED_TRACE": str(trace)},
        results_xml=str(elf.with_name(elf.stem + ".result.xml")), log_file=log)
    assert re.search(r"\d+ instructions matched Spike", log.read_text())
