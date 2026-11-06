from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge
from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


@cocotb.test()
async def counts_and_wraps(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    await ClockCycles(dut.clk, 2)
    dut.rst.value = 0

    # Compare against a Python model every cycle; 300 cycles covers the wrap past 255.
    expected = 0
    for _ in range(300):
        await RisingEdge(dut.clk)
        await ReadOnly()
        expected = (expected + 1) % 256
        assert int(dut.count.value) == expected


def test_counter():
    runner = get_runner("verilator")
    runner.build(
        sources=[HERE / "counter.sv"],
        hdl_toplevel="counter",
        build_dir=ROOT / "build" / "smoke",
        always=True,
    )
    runner.test(hdl_toplevel="counter", test_module="test_counter", test_dir=HERE)
