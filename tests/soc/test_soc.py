"""The whole SoC in simulation (tb_soc: the SoC plus a model of the SDRAM chip). The boot ROM
jumps to a C program in RAM; the test reads its output from the UART pin."""

import os
import struct
import zlib
from pathlib import Path

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from soc_sim import (SW, build_bootloader, build_bootrom, build_coremark, build_program, build_soc,
                     uart_monitor, uart_send)

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
        if b"DONE\r\n" in bytes(received):   # the whole line, not just the word
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
async def perf(dut):
    """Performance counters on kernels with exactly known event counts (sw/soc/perf_test.c)."""
    text = await run_until_done(dut, 1_000_000)
    # 100 branches, 99 taken. With the default gshare predictor: the first is a BTB miss, then each
    # new value of the 8-bit global history finds a fresh (weakly not taken) counter until the
    # history is all "taken" (up to 9 misses; fewer if the history before the loop already ended
    # in taken branches), and the loop exit is the last miss. Measured: 10 (99 with no predictor).
    # Instructions from the first minstret read up to the second: the read itself, li, 200 in the
    # loop, 2 counter reads.
    assert "loop: branches 100 mispredicts 10 instret 204\r\n" in text
    assert "load-use: 50\r\n" in text
    assert "divide wait: 330\r\n" in text        # 33 cycles per divide
    assert "multiply wait: 20\r\n" in text       # 2 cycles per multiply
    # A bus read: one cycle until the peripheral acks, one for the bridge's registered read data.
    assert "bus read wait: 2\r\n" in text


@cocotb.test()
async def cached_program(dut):
    """A program running from SDRAM: every instruction and data access goes through the caches."""
    text = await run_until_done(dut, 6_000_000)
    assert "running from 0x4000" in text
    assert "CACHE PASS\r\n" in text
    misses = {name: int(text.split(f"{name} accesses ")[1].split()[2]) for name in ("icache", "dcache")}
    assert misses["icache"] > 0 and misses["dcache"] > 0, "the caches were never missed"


@cocotb.test()
async def coremark(dut):
    """CoreMark, a few iterations. Its results (list, matrix and state CRCs) must be the known
    values for the 2K performance run. CoreMark also flags any run shorter than 10 seconds as an
    error; that's the only error allowed here (the board run is long enough)."""
    text = await run_until_done(dut, 20_000_000)
    assert "COREMARK DONE" in text
    value = {k.strip(): v.strip() for k, v in
             (line.split(":", 1) for line in text.splitlines() if ":" in line)}
    assert "2K performance run parameters for coremark." in text
    for name, crc in (("seedcrc", "0xe9f5"), ("[0]crclist", "0xe714"),
                      ("[0]crcmatrix", "0x1fd7"), ("[0]crcstate", "0x8e3a")):
        assert value[name] == crc, f"{name} is {value[name]}, should be {crc}"
    errors = [line for line in text.splitlines() if "ERROR" in line]
    assert errors == ["ERROR! Must execute for at least 10 secs for a valid result!"], errors
    cycles, iterations = int(value["Timed cycles"]), int(value["Iterations"])
    instret, branches, misp = (int(value[k]) for k in ("Timed instret", "Timed branches",
                                                         "Timed mispredicts"))
    dut._log.info(f"CoreMark/MHz {iterations * 1e6 / cycles:.3f}, CPI {cycles / instret:.3f}, "
                  f"mispredicts {misp}/{branches} ({100 * misp / branches:.1f} %)")


@cocotb.test()
async def memory_paths(dut):
    """SDRAM through the caches (bursts) and through the uncached alias (single words)."""
    text = await run_until_done(dut, 6_000_000)
    assert "DIAG PASS\r\n" in text


@cocotb.test()
async def sdram(dut):
    text = await run_until_done(dut, 2_000_000)
    assert "SDRAM PASS\r\n" in text
    dut._log.info(f"{int(dut.sdram_refreshes.value)} SDRAM refreshes, 0 violations")


@cocotb.test()
async def bootloader(dut):
    """The real boot ROM: wait for 'ready', send hello.bin over the UART like tools/upload.py,
    and the program must run."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.rxd.value = 1
    dut.sw.value = 0x155
    dut.key_n.value = 0b11
    dut.rst.value = 1
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0
    received = []
    cocotb.start_soon(uart_monitor(dut, received))
    while b"ready" not in bytes(received):
        await ClockCycles(dut.clk, 1000)

    image = Path(os.environ["PROGRAM_BIN"]).read_bytes()
    packet = b"BOOT" + struct.pack("<I", len(image)) + image + struct.pack("<I", zlib.crc32(image))

    # First a copy with one byte flipped: it must be rejected, and the board must be ready again.
    corrupted = bytearray(packet)
    corrupted[100] ^= 0x01
    await uart_send(dut, corrupted)
    while bytes(received).count(b"ready") < 2:
        await ClockCycles(dut.clk, 1000)
    assert b"ERR crc" in bytes(received)

    await uart_send(dut, packet)
    for _ in range(1000):
        await ClockCycles(dut.clk, 1000)
        if b"DONE" in bytes(received):
            break
    text = bytes(received).decode()
    for line in text.splitlines():
        dut._log.info(f"uart: {line}")
    assert "OK\r\nstarting program\r\nHello from rv32im-core!" in text
    assert text.endswith("DONE\r\n")
    dut._log.info(f"uploaded {len(image)} bytes")


@cocotb.test()
async def load_command(dut):
    """LOAD 16 bytes into SDRAM, then BOOT a program that prints them back."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.rxd.value = 1
    dut.sw.value = 0
    dut.key_n.value = 0b11
    dut.rst.value = 1
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0
    received = []
    cocotb.start_soon(uart_monitor(dut, received))
    while b"ready" not in bytes(received):
        await ClockCycles(dut.clk, 1000)

    data = b"LOAD works ok!\r\n"
    await uart_send(dut, b"LOAD" + struct.pack("<II", 0x40001000, len(data)) + data +
                    struct.pack("<I", zlib.crc32(data)))
    while bytes(received).count(b"ready") < 2:
        await ClockCycles(dut.clk, 1000)
    assert b"OK" in bytes(received)

    image = Path(os.environ["PROGRAM_BIN"]).read_bytes()
    await uart_send(dut, b"BOOT" + struct.pack("<I", len(image)) + image +
                    struct.pack("<I", zlib.crc32(image)))
    for _ in range(1000):
        await ClockCycles(dut.clk, 1000)
        if b"DONE\r\n" in bytes(received):
            break
    text = bytes(received).decode()
    for line in text.splitlines():
        dut._log.info(f"uart: {line}")
    assert "loaded: LOAD works ok!" in text


@pytest.fixture(scope="module")
def soc_runner():
    return build_soc()


@pytest.mark.parametrize("program", ["hello", "sdram_test", "perf_test", "sdram_diag"])
def test_soc(soc_runner, program):
    bootrom = build_bootrom(SW / "boot" / "jump_to_ram.S")
    hexfile = build_program(SW / "soc" / f"{program}.c")
    soc_runner.test(
        hdl_toplevel="tb_soc",
        test_module="test_soc",
        testcase={"sdram_test": "sdram", "perf_test": "perf", "sdram_diag": "memory_paths"}.get(program, program),
        test_dir=HERE,
        plusargs=[f"+bootrom={bootrom}", f"+program={hexfile}"],
        results_xml=str(hexfile.with_suffix(".result.xml")),
    )


def test_bootloader(soc_runner):
    bootrom = build_bootloader()
    hexfile = build_program(SW / "soc" / "hello.c")
    soc_runner.test(
        hdl_toplevel="tb_soc",
        test_module="test_soc",
        testcase="bootloader",
        test_dir=HERE,
        plusargs=[f"+bootrom={bootrom}"],   # RAM starts empty: the program comes over the UART
        extra_env={"PROGRAM_BIN": str(hexfile.with_suffix(".bin"))},
        results_xml=str(bootrom.with_suffix(".result.xml")),
    )


def test_bootloader_load(soc_runner):
    bootrom = build_bootloader()
    hexfile = build_program(SW / "soc" / "loadcheck.c")
    soc_runner.test(
        hdl_toplevel="tb_soc",
        test_module="test_soc",
        testcase="load_command",
        test_dir=HERE,
        plusargs=[f"+bootrom={bootrom}"],
        extra_env={"PROGRAM_BIN": str(hexfile.with_suffix(".bin"))},
        results_xml=str(hexfile.with_suffix(".result.xml")),
    )


@pytest.mark.parametrize("where", ["ram", "sdram"])
def test_coremark(soc_runner, where):
    bootrom = build_bootrom(SW / "boot" / ("jump_to_sdram.S" if where == "sdram" else "jump_to_ram.S"))
    program = build_coremark(2, sdram=where == "sdram")
    soc_runner.test(
        hdl_toplevel="tb_soc",
        test_module="test_soc",
        testcase="coremark",
        test_dir=HERE,
        plusargs=[f"+bootrom={bootrom}",
                  f"+sdram_init={program}" if where == "sdram" else f"+program={program}"],
        results_xml=str(program.with_suffix(".result.xml")),
    )


def test_from_sdram(soc_runner):
    bootrom = build_bootrom(SW / "boot" / "jump_to_sdram.S")
    program = build_program(SW / "soc" / "cache_test.c", name="soc-cache_test-sdram", sdram=True)
    soc_runner.test(
        hdl_toplevel="tb_soc",
        test_module="test_soc",
        testcase="cached_program",
        test_dir=HERE,
        plusargs=[f"+bootrom={bootrom}", f"+sdram_init={program}"],
        results_xml=str(program.with_suffix(".result.xml")),
    )
