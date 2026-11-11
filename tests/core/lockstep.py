"""The cocotb side of the lockstep test: run the core and compare every retired instruction
with Spike's trace (PC, instruction, register write, memory access)."""

import json
import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

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
        assert got == exp, f"mismatch at instruction #{retired}\n  spike: {describe(exp)}\n  core:  {describe(got)}"
        retired += 1

    result = expected[-1]["store_data"]
    dut._log.info(f"{retired} instructions matched Spike in {cycles} cycles")
    assert result == 1, f"program reported failure at check {result >> 1}"
