"""The ASIC top level (rtl/rv32im_asic.sv) as the ASIC flow sees it: ASIC defined, so the cache
RAMs are flip-flops. Verilator's lint must pass with every warning on except unused bits of
helper variables inside functions (its behaviour is checked by
the cached lockstep tests, which run the same module)."""

import subprocess

from sim import ROOT, RTL

SOURCES = ["rv_pkg.sv", "alu.sv", "regfile.sv", "decoder.sv", "muldiv.sv", "csr.sv", "bpred.sv",
           "core.sv", "cache_ram.sv", "cache.sv", "mem_arbiter.sv", "rv32im_asic.sv"]


def test_asic_top_lints():
    result = subprocess.run(
        ["verilator", "--lint-only", "-Wall", "-Wno-UNUSEDSIGNAL", "-DASIC", "--top-module", "rv32im_asic",
         *[str(RTL / f) for f in SOURCES]],
        capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stderr
