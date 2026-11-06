"""Lockstep tests: every program in tests/asm runs on the core and on Spike, and every
retired instruction must match (PC, instruction, register write, memory access)."""

import json
import os
from pathlib import Path

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PROGRAMS = sorted((ROOT / "tests" / "asm").glob("*.S"))
MAX_IDLE_CYCLES = 100   # no instruction retiring for this long means the core is stuck


def describe(e):
    text = f"pc={e['pc']:#010x} insn={e['insn']:#010x}"
    if e["rd"]:
        text += f" x{e['rd']}={e['rd_wdata']:#010x}"
    if e["mem"] == "load":
        text += f" load@{e['mem_addr']:#010x}"
    if e["mem"] == "store":
        text += f" store{e['store_bytes']}@{e['mem_addr']:#010x}={e['store_data']:#x}"
    return text


def sample(dut):
    wmask = int(dut.rvfi_mem_wmask.value)
    mem = "store" if wmask else "load" if int(dut.rvfi_mem_read.value) else None
    return {
        "pc": int(dut.rvfi_pc.value),
        "insn": int(dut.rvfi_insn.value),
        "rd": int(dut.rvfi_rd.value),
        "rd_wdata": int(dut.rvfi_rd_wdata.value),
        "mem": mem,
        "mem_addr": int(dut.rvfi_mem_addr.value) if mem else 0,
        "store_data": int(dut.rvfi_mem_wdata.value) if wmask else 0,
        "store_bytes": bin(wmask).count("1"),
    }


@cocotb.test()
async def lockstep(dut):
    expected = json.loads(Path(os.environ["EXPECTED_TRACE"]).read_text())
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0

    retired = idle = cycles = 0
    while retired < len(expected):
        await RisingEdge(dut.clk)
        await ReadOnly()
        cycles += 1
        if not int(dut.rvfi_valid.value):
            idle += 1
            assert idle < MAX_IDLE_CYCLES, f"nothing retired for {idle} cycles after #{retired}"
            continue
        idle = 0
        got, exp = sample(dut), expected[retired]
        assert not int(dut.rvfi_trap.value), f"#{retired}: trap at {describe(got)}"
        assert got == exp, f"mismatch at instruction #{retired}\n  spike: {describe(exp)}\n  core:  {describe(got)}"
        retired += 1

    result = expected[-1]["store_data"]
    dut._log.info(f"{retired} instructions matched Spike in {cycles} cycles")
    assert result == 1, f"program reported failure at check {result >> 1}"


@pytest.fixture(scope="module")
def runner():
    from cocotb_tools.runner import get_runner
    runner = get_runner("verilator")
    rtl = ROOT / "rtl"
    runner.build(
        sources=[rtl / "rv_pkg.sv", rtl / "alu.sv", rtl / "regfile.sv", rtl / "decoder.sv",
                 rtl / "ram.sv", rtl / "core.sv", ROOT / "tb" / "tb_top.sv"],
        hdl_toplevel="tb_top",
        build_dir=ROOT / "build" / "tb_top",
        build_args=["-Wall"],
        always=True,
    )
    return runner


@pytest.mark.parametrize("src", PROGRAMS, ids=lambda p: p.stem)
def test_program(runner, src):
    from programs import build, spike_trace
    elf, hexfile, tohost = build(src)
    trace = elf.with_suffix(".trace.json")
    trace.write_text(json.dumps(spike_trace(elf, tohost)))
    runner.test(
        hdl_toplevel="tb_top",
        test_module="test_programs",
        test_dir=HERE,
        plusargs=[f"+program={hexfile}"],
        extra_env={"EXPECTED_TRACE": str(trace)},
        results_xml=str(elf.with_suffix(".result.xml")),
    )
