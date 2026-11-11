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

RTL_SOURCES = ["rv_pkg.sv", "alu.sv", "regfile.sv", "decoder.sv", "muldiv.sv", "csr.sv", "dpram.sv",
               "bpred.sv", "core.sv", "wb_uart.sv", "wb_timer.sv", "wb_gpio.sv", "fb_ram.sv", "fb8_ram.sv", "wb_vga.sv",
               "sdram_ctrl.sv", "cache_ram.sv", "cache.sv", "mem_arbiter.sv", "npu/lint.vlt", "npu/pe.v", "npu/systolic_array.v", "npu/sdp_ram.sv",
               "npu/wb_npu.sv", "soc.sv"]
TB_SOURCES = ["sdram_model.sv", "vga_capture.sv", "tb_soc.sv"]


def build_program(src, extra_flags=(), name=None, sdram=False):
    """A C program with crt0 and the driver library, for on-chip RAM (or for SDRAM with
    sw/sdram.ld). Returns the hex path."""
    _, hexfile, _ = build(src, [SW / "lib"], name=name or f"soc-{src.stem}",
                          extra_sources=[SW / "crt0.S", *LIB], extra_flags=[*C_FLAGS, *extra_flags],
                          linker_script=SW / ("sdram.ld" if sdram else "link.ld"))
    return hexfile


COREMARK = ROOT / "third_party" / "coremark"
COREMARK_FLAGS = ["-O2", "-ffreestanding"]


def build_coremark(iterations, sdram=False, name=None):
    """CoreMark (third_party/coremark with the port in sw/coremark), for on-chip RAM or SDRAM.
    iterations=0 lets CoreMark pick a count that runs for about 10 seconds. Returns the hex path."""
    flags = " ".join(COREMARK_FLAGS + ["-march=rv32im_zicsr_zifencei", "-mabi=ilp32"])
    _, hexfile, _ = build(
        COREMARK / "core_main.c", [SW / "coremark", COREMARK, SW / "lib"],
        name=name or f"coremark-{'sdram' if sdram else 'ram'}-{iterations}",
        extra_sources=[SW / "crt0.S", SW / "lib" / "uart.c", SW / "lib" / "printf.c",
                       SW / "coremark" / "core_portme.c",
                       *(COREMARK / f for f in ("core_list_join.c", "core_matrix.c", "core_state.c",
                                                "core_util.c"))],
        extra_flags=[*COREMARK_FLAGS, f"-DITERATIONS={iterations}",
                     f'-DCOMPILER_FLAGS="{flags}"',
                     f'-DMEM_LOCATION="{"SDRAM via caches" if sdram else "on-chip RAM"}"'],
        linker_script=SW / ("sdram.ld" if sdram else "link.ld"))
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


def build_soc(parameters=None, tag=""):
    """tb_soc with the default configuration, or with other cache/predictor parameters (tb_soc.sv)
    built in build/tb_soc<tag>."""
    from cocotb_tools.runner import get_runner
    runner = get_runner("verilator")
    runner.build(
        sources=[ROOT / "rtl" / f for f in RTL_SOURCES] + [ROOT / "tb" / f for f in TB_SOURCES],
        hdl_toplevel="tb_soc",
        build_dir=ROOT / "build" / f"tb_soc{tag}",
        build_args=["-Wall"],
        parameters={"UART_DIVISOR": UART_DIVISOR, **(parameters or {})},
        always=True,
    )
    return runner


async def uart_send(dut, data, divisor=UART_DIVISOR):
    """Drive bytes into dut.rxd: start bit, 8 data bits LSB first, stop bit."""
    for byte in data:
        for bit in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
            dut.rxd.value = bit
            await ClockCycles(dut.clk, divisor)


async def uart_monitor(dut, received, rate=None):
    """Decode bytes from dut.txd into the list `received`, forever. rate: [clocks per bit] or
    [clocks per bit, new clocks per bit]: with the second, the monitor switches as soon as it has
    received "OK" (like the host after the bootloader's BAUD command)."""
    rate = rate or [UART_DIVISOR]
    while True:
        await FallingEdge(dut.txd)                       # start bit
        divisor = rate[0]
        await ClockCycles(dut.clk, divisor // 2)         # middle of the start bit
        value = 0
        for bit in range(8):
            await ClockCycles(dut.clk, divisor)
            value |= int(dut.txd.value) << bit
        await ClockCycles(dut.clk, divisor)              # stop bit
        received.append(value)
        if len(rate) > 1 and rate[1] and bytes(received).endswith(b"OK\r\n"):
            rate[0], rate[1] = rate[1], None
