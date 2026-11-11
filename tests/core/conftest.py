"""Shared by the core-level tests: the core is built with Verilator once per test session (once
per testbench and cache configuration), and each program is then run on it in lockstep with
Spike."""

import json
import re
from pathlib import Path

import pytest

from programs import ROOT, build, spike_trace

HERE = Path(__file__).resolve().parent
RTL_SOURCES = ["rv_pkg.sv", "alu.sv", "regfile.sv", "decoder.sv", "muldiv.sv", "csr.sv", "dpram.sv",
               "bpred.sv", "core.sv"]
CACHE_SOURCES = ["cache_ram.sv", "cache.sv", "mem_arbiter.sv"]

# Cache configurations the lockstep tests also run through (tb/tb_cached.sv). Tiny caches, so
# lines are evicted (and dirty lines written back) all the time.
CACHE_CONFIGS = {
    "dm256":  dict(ICACHE_SIZE=256, ICACHE_WAYS=1, DCACHE_SIZE=256, DCACHE_WAYS=1),
    "2way256": dict(ICACHE_SIZE=256, ICACHE_WAYS=2, DCACHE_SIZE=256, DCACHE_WAYS=2),
}

# Branch predictor configurations the lockstep tests also run with (tb/tb_top.sv): none, and
# tiny tables (4-entry BTB, 16 counters, 2-entry return stack) so entries alias and get replaced
# all the time. The other testbenches use the core's default predictor.
BP_CONFIGS = {
    "nobp":    dict(BP_MODE=0),
    "bimodal": dict(BP_MODE=1, BTB_BITS=2, BHT_BITS=4, RAS_DEPTH=2),
    "gshare":  dict(BP_MODE=2, BTB_BITS=2, BHT_BITS=4, RAS_DEPTH=2),
}

_runners = {}


def get_core_runner(config=None):
    """The plain testbench (tb_top) for config=None or a BP_CONFIGS name, else tb_cached with that
    cache config."""
    if config not in _runners:
        from cocotb_tools.runner import get_runner
        runner = get_runner("verilator")
        if config is None or config in BP_CONFIGS:
            sources = [ROOT / "rtl" / f for f in RTL_SOURCES] + [ROOT / "tb" / "tb_top.sv"]
            runner.build(sources=sources, hdl_toplevel="tb_top",
                         build_dir=ROOT / "build" / ("tb_top" + (f"_{config}" if config else "")),
                         parameters=BP_CONFIGS.get(config, {}), build_args=["-Wall"], always=True)
        else:
            sources = ([ROOT / "rtl" / f for f in RTL_SOURCES + CACHE_SOURCES] +
                       [ROOT / "tb" / "line_mem.sv", ROOT / "tb" / "tb_cached.sv"])
            runner.build(sources=sources, hdl_toplevel="tb_cached",
                         build_dir=ROOT / "build" / f"tb_cached_{config}",
                         parameters=CACHE_CONFIGS[config], build_args=["-Wall"], always=True)
        _runners[config] = runner
    return _runners[config]


def lockstep(src, includes, name=None, plusargs=(), config=None, **build_options):
    """Build the program, record Spike's trace, and run the `lockstep` cocotb test (lockstep.py)
    on the plain or a cached testbench. Returns (instructions, cycles)."""
    elf, hexfile, tohost = build(src, includes, name, **build_options)
    trace = elf.with_suffix(".trace.json")
    trace.write_text(json.dumps(spike_trace(elf, tohost)))
    tag = f"-{config}" if config else ""
    log = elf.with_name(elf.stem + tag + ".log")
    get_core_runner(config).test(
        hdl_toplevel="tb_cached" if config in CACHE_CONFIGS else "tb_top",
        test_module="lockstep",
        test_dir=HERE,
        plusargs=[f"+program={hexfile}", *plusargs],
        extra_env={"EXPECTED_TRACE": str(trace)},
        results_xml=str(elf.with_name(elf.stem + tag + ".result.xml")),
        log_file=log,
    )
    stats = re.search(r"(\d+) instructions matched Spike in (\d+) cycles", log.read_text())
    return int(stats[1]), int(stats[2])


@pytest.fixture
def run_lockstep():
    """run_lockstep(src, includes, name, plusargs, config=None, ...): see lockstep()."""
    return lockstep
