"""Shared by the SoC tests: building SoC software, building the SoC with Verilator, and a UART
decoder that turns the txd pin back into text (what a terminal would show)."""

import sys
from pathlib import Path

from cocotb.triggers import ClockCycles, FallingEdge

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "core"))
from programs import build  # noqa: E402

SW = ROOT / "sw"
LIB = sorted((SW / "lib").glob("*.c"))
C_FLAGS = ["-O2", "-ffreestanding", "-fno-builtin", "-Wall", "-Werror"]
UART_DIVISOR = 8   # clock cycles per bit in simulation (the board uses 434 for 115200 baud)

RTL_SOURCES = ["rv_pkg.sv", "alu.sv", "regfile.sv", "decoder.sv", "muldiv.sv", "dpram.sv",
               "core.sv", "wb_uart.sv", "wb_timer.sv", "wb_gpio.sv", "sdram_ctrl.sv", "soc.sv"]
TB_SOURCES = ["sdram_model.sv", "tb_soc.sv"]


def build_program(src):
    """A C program for on-chip RAM, with crt0 and the driver library. Returns the hex path."""
    _, hexfile, _ = build(src, [SW / "lib"], name=f"soc-{src.stem}",
                          extra_sources=[SW / "crt0.S", *LIB], extra_flags=C_FLAGS)
    return hexfile


def build_bootrom(src, extra_sources=()):
    """A boot ROM image (linked at address 0 with sw/boot/rom.ld). Returns the hex path."""
    _, hexfile, _ = build(src, [SW / "lib"], name=f"bootrom-{src.stem}",
                          extra_sources=extra_sources, extra_flags=C_FLAGS,
                          linker_script=SW / "boot" / "rom.ld")
    return hexfile


def build_bootloader():
    return build_bootrom(SW / "boot" / "bootloader.c",
                         extra_sources=[SW / "boot" / "start.S", SW / "lib" / "uart.c"])


def build_soc():
    from cocotb_tools.runner import get_runner
    runner = get_runner("verilator")
    runner.build(
        sources=[ROOT / "rtl" / f for f in RTL_SOURCES] + [ROOT / "tb" / f for f in TB_SOURCES],
        hdl_toplevel="tb_soc",
        build_dir=ROOT / "build" / "tb_soc",
        build_args=["-Wall"],
        parameters={"UART_DIVISOR": UART_DIVISOR},
        always=True,
    )
    return runner


async def uart_send(dut, data):
    """Drive bytes into dut.rxd: start bit, 8 data bits LSB first, stop bit."""
    for byte in data:
        for bit in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
            dut.rxd.value = bit
            await ClockCycles(dut.clk, UART_DIVISOR)


async def uart_monitor(dut, received):
    """Decode bytes from dut.txd into the list `received`, forever."""
    while True:
        await FallingEdge(dut.txd)                       # start bit
        await ClockCycles(dut.clk, UART_DIVISOR // 2)    # middle of the start bit
        value = 0
        for bit in range(8):
            await ClockCycles(dut.clk, UART_DIVISOR)
            value |= int(dut.txd.value) << bit
        await ClockCycles(dut.clk, UART_DIVISOR)         # stop bit
        received.append(value)
