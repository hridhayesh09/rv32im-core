"""The whole SoC in simulation (tb_soc: the SoC plus a model of the SDRAM chip). The boot ROM
jumps to a C program in RAM; the test reads its output from the UART pin."""

from pathlib import Path

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from soc_sim import SW, build_bootrom, build_program, build_soc, uart_monitor

HERE = Path(__file__).resolve().parent
SEGMENTS = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07,
            0x7F, 0x6F, 0x77, 0x7C, 0x39, 0x5E, 0x79, 0x71]


async def run_until_done(dut, max_cycles):
    """Reset, run until the program prints DONE, and return everything it printed."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())   # 50 MHz
    dut.rxd.value = 1
    dut.sw.value = 0x155
    dut.key_n.value = 0b11
    dut.rst.value = 1
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0

    received = []
    cocotb.start_soon(uart_monitor(dut, received))
    for _ in range(max_cycles // 1000):
        await ClockCycles(dut.clk, 1000)
        if b"DONE" in bytes(received):
            break
    text = bytes(received).decode()
    for line in text.splitlines():
        dut._log.info(f"uart: {line}")
    assert text.endswith("DONE\r\n"), "program didn't finish"
    assert int(dut.sdram_violations.value) == 0, "SDRAM rule violations"
    return text


@cocotb.test()
async def hello(dut):
    text = await run_until_done(dut, 500_000)
    assert "Hello from rv32im-core!\r\n" in text
    assert "fib(30) = 832040" in text
    assert "switches = 0x155\r\n" in text
    assert "printf check: [  -42] [  7] [0000beef] [ok] [Z] [%]\r\n" in text
    assert int(dut.ledr.value) == 0x2AA
    lit = ~int(dut.hex_n.value) & (2**48 - 1)
    shown = [(lit >> (8 * i)) & 0xFF for i in range(6)]
    assert shown == [SEGMENTS[(0xC0FFEE >> (4 * i)) & 0xF] for i in range(6)]


@cocotb.test()
async def sdram(dut):
    text = await run_until_done(dut, 2_000_000)
    assert "SDRAM PASS\r\n" in text
    dut._log.info(f"{int(dut.sdram_refreshes.value)} SDRAM refreshes, 0 violations")


@pytest.fixture(scope="module")
def soc_runner():
    return build_soc()


@pytest.mark.parametrize("program", ["hello", "sdram_test"])
def test_soc(soc_runner, program):
    bootrom = build_bootrom(SW / "boot" / "jump_to_ram.S")
    hexfile = build_program(SW / "soc" / f"{program}.c")
    soc_runner.test(
        hdl_toplevel="tb_soc",
        test_module="test_soc",
        testcase="sdram" if program == "sdram_test" else program,
        test_dir=HERE,
        plusargs=[f"+bootrom={bootrom}", f"+program={hexfile}"],
        results_xml=str(hexfile.with_suffix(".result.xml")),
    )
