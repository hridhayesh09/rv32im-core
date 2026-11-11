"""SDRAM controller against the chip model (tb/sdram_model.sv), which checks every timing and
protocol rule. Random reads and writes with random byte masks, compared with a Python dict."""

import random

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge, Timer

from sim import ROOT, run
from wishbone import WishboneMaster


async def line_access(dut, addr, we=False, data=0):
    """One 16-byte line through the cache port. Returns the data read (as an int, word 0 lowest)."""
    await FallingEdge(dut.clk)
    dut.line_req.value = 1
    dut.line_we.value = int(we)
    dut.line_addr.value = addr
    dut.line_wdata.value = data
    for _ in range(12000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.line_ack.value):
            value = int(dut.line_rdata.value)
            break
    else:
        raise AssertionError(f"no line_ack for {addr:#x}")
    await FallingEdge(dut.clk)
    dut.line_req.value = 0
    return value


async def start(dut):
    dut.line_req.value = 0
    dut.line_we.value = 0
    dut.line_addr.value = 0
    dut.line_wdata.value = 0
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())   # 50 MHz
    # The first access waits for the controller's 200 us power-up sequence (10,000 cycles).
    bus = WishboneMaster(dut, timeout=12000)
    dut.rst.value = 1
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0
    return bus


@cocotb.test()
async def random_access(dut):
    bus = await start(dut)
    rng = random.Random(7)
    model = {}
    # A mix of a few hot addresses (same row and bank again and again), and anywhere in 64 MB.
    hot = [rng.randrange(0, 1 << 26, 4) for _ in range(16)]
    for i in range(3000):
        addr = rng.choice(hot) if rng.random() < 0.5 else rng.randrange(0, 1 << 26, 4)
        if rng.random() < 0.5 or addr not in model:
            sel = rng.choice([0xF, 0xF, 0x1, 0x2, 0x4, 0x8, 0x3, 0xC])
            data = rng.getrandbits(32)
            await bus.write(addr, data, sel)
            old = model.get(addr, 0)
            mask = sum(0xFF << (8 * b) for b in range(4) if sel >> b & 1)
            model[addr] = (old & ~mask) | (data & mask)
        else:
            got = await bus.read(addr)
            assert got == model[addr], f"read {addr:#x}: got {got:#010x}, expected {model[addr]:#010x}"
    assert int(dut.violations.value) == 0, f"{int(dut.violations.value)} SDRAM rule violations"
    dut._log.info(f"{int(dut.refreshes.value)} refreshes, 0 violations")
    assert int(dut.refreshes.value) > 8


@cocotb.test()
async def lines_and_words(dut):
    """16-byte lines (the caches' port) mixed with single words (Wishbone), on the same memory."""
    bus = await start(dut)
    rng = random.Random(8)
    model = {}                              # word address -> value
    lines = [rng.randrange(0, 1 << 26, 16) for _ in range(24)]
    for i in range(1500):
        line = rng.choice(lines)
        r = rng.random()
        if r < 0.3:                         # write a whole line
            data = rng.getrandbits(128)
            await line_access(dut, line, True, data)
            for w in range(4):
                model[line + 4 * w] = (data >> (32 * w)) & 0xFFFFFFFF
        elif r < 0.6 and all(line + 4 * w in model for w in range(4)):   # read a whole line
            got = await line_access(dut, line)
            expected = sum(model[line + 4 * w] << (32 * w) for w in range(4))
            assert got == expected, f"line {line:#x}: got {got:#034x}, expected {expected:#034x}"
        elif r < 0.8:                       # write one word (maybe one byte) inside a line
            addr = line + 4 * rng.randrange(4)
            sel = rng.choice([0xF, 0x1, 0x8, 0x6])
            data = rng.getrandbits(32)
            await bus.write(addr, data, sel)
            mask = sum(0xFF << (8 * b) for b in range(4) if sel >> b & 1)
            model[addr] = (model.get(addr, 0) & ~mask) | (data & mask)
        else:                               # read one word
            addr = line + 4 * rng.randrange(4)
            if addr in model:
                assert await bus.read(addr) == model[addr], f"word {addr:#x}"
    assert int(dut.violations.value) == 0, f"{int(dut.violations.value)} SDRAM rule violations"
    dut._log.info(f"{int(dut.refreshes.value)} refreshes, 0 violations")


@cocotb.test()
async def refresh_while_idle(dut):
    """No accesses for 1 ms: the controller must keep refreshing on its own."""
    await start(dut)
    await Timer(1, unit="ms")
    assert int(dut.violations.value) == 0
    # 1 ms / 7.8 us is about 128 refreshes, minus the 200 us power-up wait
    assert int(dut.refreshes.value) >= 100


# Each test in its own simulation: the chip model must see a real power-up every time.
@pytest.mark.parametrize("testcase", ["random_access", "lines_and_words", "refresh_while_idle"])
def test_sdram(testcase):
    run("tb_sdram", ["sdram_ctrl.sv", ROOT / "tb" / "sdram_model.sv", ROOT / "tb" / "tb_sdram.sv"],
        "test_sdram", testcase=testcase)
