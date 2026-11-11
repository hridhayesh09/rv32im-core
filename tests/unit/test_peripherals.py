"""Unit tests for the Wishbone peripherals: UART, timer, GPIO."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

from sim import run
from wishbone import WishboneMaster

DIVISOR = 8   # clock cycles per UART bit in these tests (the real default is 434)


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    bus = WishboneMaster(dut)
    dut.rst.value = 1
    await ClockCycles(dut.clk, 2)
    dut.rst.value = 0
    return bus


# ---------------------------------------------------------------- UART

async def uart_receive_line(dut, divisor):
    """Decode one byte from dut.txd, the way a terminal would."""
    while int(dut.txd.value) == 1:
        await RisingEdge(dut.clk)
    await ClockCycles(dut.clk, divisor // 2)          # middle of the start bit
    assert int(dut.txd.value) == 0, "start bit too short"
    value = 0
    for bit in range(8):
        await ClockCycles(dut.clk, divisor)
        value |= int(dut.txd.value) << bit
    await ClockCycles(dut.clk, divisor)
    assert int(dut.txd.value) == 1, "missing stop bit"
    return value


async def uart_send_line(dut, byte, divisor):
    """Drive one byte into dut.rxd: start bit, 8 data bits LSB first, stop bit."""
    for bit in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
        await FallingEdge(dut.clk)
        dut.rxd.value = bit
        await ClockCycles(dut.clk, divisor)


@cocotb.test()
async def uart_transmit(dut):
    dut.rxd.value = 1
    bus = await setup(dut)
    await bus.write(0x8, DIVISOR)
    assert await bus.read(0x8) == DIVISOR
    for byte in [0x55, 0x00, 0xFF, 0x0A] + [random.Random(6).randrange(256) for _ in range(8)]:
        while not (await bus.read(0x4)) & 1:          # wait for tx_ready
            pass
        await bus.write(0x0, byte)
        assert await uart_receive_line(dut, DIVISOR) == byte


@cocotb.test()
async def uart_receive(dut):
    dut.rxd.value = 1
    bus = await setup(dut)
    await bus.write(0x8, DIVISOR)
    assert (await bus.read(0x4)) & 2 == 0, "rx_valid set with nothing received"
    for byte in [0xA5, 0x00, 0xFF, 0x31]:
        await uart_send_line(dut, byte, DIVISOR)
        await ClockCycles(dut.clk, DIVISOR)
        assert (await bus.read(0x4)) & 2, "rx_valid not set"
        assert await bus.read(0x0) == byte
        assert (await bus.read(0x4)) & 2 == 0, "reading DATA didn't clear rx_valid"

    # Bytes received without reading wait in the 64-byte FIFO, in order; the 65th is lost and
    # overrun is flagged.
    sent = [(i * 37 + 5) & 0xFF for i in range(65)]
    for byte in sent:
        await uart_send_line(dut, byte, DIVISOR)
    await ClockCycles(dut.clk, DIVISOR)
    assert (await bus.read(0x4)) & 6 == 6, "overrun not flagged"
    got = [await bus.read(0x0) for _ in range(64)]
    assert got == sent[:64], "FIFO order"
    assert (await bus.read(0x4)) & 6 == 0, "FIFO not empty, or overrun not cleared"


@cocotb.test()
async def uart_ignores_glitch(dut):
    """A low pulse shorter than half a bit is not a start bit."""
    dut.rxd.value = 1
    bus = await setup(dut)
    await bus.write(0x8, DIVISOR)
    await FallingEdge(dut.clk)
    dut.rxd.value = 0
    await ClockCycles(dut.clk, 2)
    dut.rxd.value = 1
    await ClockCycles(dut.clk, DIVISOR * 12)
    assert (await bus.read(0x4)) & 2 == 0


def test_uart():
    run("wb_uart", ["wb_uart.sv"], "test_peripherals",
        testcase=["uart_transmit", "uart_receive", "uart_ignores_glitch"])


# ---------------------------------------------------------------- timer

@cocotb.test()
async def timer_counts(dut):
    bus = await setup(dut)
    t0 = await bus.read(0x0)
    await ClockCycles(dut.clk, 100)
    t1 = await bus.read(0x0)
    # 100 cycles waited, plus the cycles the two reads themselves take
    assert 100 < t1 - t0 < 110, f"counter advanced {t1 - t0}"
    assert await bus.read(0x14) == 50_000_000


@cocotb.test()
async def timer_compare(dut):
    bus = await setup(dut)
    now = await bus.read(0x0)
    await bus.write(0x8, now + 50)
    await bus.write(0xC, 0)
    assert await bus.read(0x10) == 0
    await ClockCycles(dut.clk, 60)
    assert await bus.read(0x10) == 1


def test_timer():
    run("wb_timer", ["wb_timer.sv"], "test_peripherals", testcase=["timer_counts", "timer_compare"])


# ---------------------------------------------------------------- GPIO

@cocotb.test()
async def gpio_leds_and_hex(dut):
    dut.sw.value = 0
    dut.key_n.value = 0b11
    bus = await setup(dut)
    await bus.write(0x0, 0x3FF)
    assert int(dut.ledr.value) == 0x3FF
    await bus.write(0x0, 0x155)
    assert int(dut.ledr.value) == 0x155
    assert await bus.read(0x0) == 0x155
    for digit in range(6):
        await bus.write(0x10 + 4 * digit, 0x40 + digit)
    await RisingEdge(dut.clk)
    for digit in range(6):
        assert await bus.read(0x10 + 4 * digit) == 0x40 + digit
        lit = (~int(dut.hex_n.value) >> (8 * digit)) & 0xFF   # pins are active low
        assert lit == 0x40 + digit


@cocotb.test()
async def gpio_inputs(dut):
    dut.sw.value = 0
    dut.key_n.value = 0b11
    bus = await setup(dut)
    dut.sw.value = 0x2A5
    dut.key_n.value = 0b10        # KEY0 pressed (active low on the board)
    await ClockCycles(dut.clk, 3)  # through the synchronizers
    assert await bus.read(0x4) == 0x2A5
    assert await bus.read(0x8) == 0b01


def test_gpio():
    run("wb_gpio", ["wb_gpio.sv"], "test_peripherals", testcase=["gpio_leds_and_hex", "gpio_inputs"])
