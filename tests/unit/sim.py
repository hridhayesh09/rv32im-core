"""Builds one RTL module with Verilator and runs its cocotb tests."""

from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "rtl"


def run(toplevel, rtl_files, test_module):
    runner = get_runner("verilator")
    runner.build(
        sources=[RTL / "rv_pkg.sv"] + [RTL / f for f in rtl_files],
        hdl_toplevel=toplevel,
        build_dir=ROOT / "build" / toplevel,
        # Verilator lint warnings fail the build. A single module never uses every
        # constant in rv_pkg, so unused-parameter warnings are off for unit builds.
        build_args=["-Wall", "-Wno-UNUSEDPARAM"],
        always=True,
    )
    runner.test(hdl_toplevel=toplevel, test_module=test_module, test_dir=Path(__file__).parent)
