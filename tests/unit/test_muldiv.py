import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge

from rv_defs import MASK32, signed32
from sim import run

OPS = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
EDGE_VALUES = [0, 1, 2, 3, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF, 0xFFFFFFFE, 0x12345678]


def trunc_div(a, b):
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def muldiv_model(op, a, b):
    sa, sb = signed32(a), signed32(b)
    if op == "mul":
        return (a * b) & MASK32
    if op == "mulh":
        return ((sa * sb) >> 32) & MASK32
    if op == "mulhsu":
        return ((sa * b) >> 32) & MASK32
    if op == "mulhu":
        return (a * b) >> 32
    if op == "div":
        if b == 0:
            return MASK32
        if sa == -(1 << 31) and sb == -1:
            return a  # overflow: the spec says the result is the dividend
        return trunc_div(sa, sb) & MASK32
    if op == "divu":
        return MASK32 if b == 0 else a // b
    if op == "rem":
        if b == 0:
            return a
        if sa == -(1 << 31) and sb == -1:
            return 0
        return (sa - sb * trunc_div(sa, sb)) & MASK32
    if op == "remu":
        return a if b == 0 else a % b
    raise ValueError(op)


async def check(dut, op, a, b):
    await FallingEdge(dut.clk)
    dut.start.value = 1
    dut.op.value = OPS.index(op)
    dut.a.value = a
    dut.b.value = b
    await FallingEdge(dut.clk)
    dut.start.value = 0
    dut.a.value = 0   # the unit must have captured its operands already
    dut.b.value = 0
    for cycles in range(1, 40):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.done.value):
            break
    else:
        raise AssertionError(f"{op} never finished")
    got, exp = int(dut.result.value), muldiv_model(op, a, b)
    assert got == exp, f"{op} {a:#010x}, {b:#010x}: got {got:#010x}, expected {exp:#010x}"
    await RisingEdge(dut.clk)   # DONE -> IDLE; a start is only accepted when idle
    return cycles


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.start.value = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 2)
    dut.rst.value = 0


@cocotb.test()
async def edge_values(dut):
    """Every op on every pair of edge values: division by zero, overflow, sign combinations."""
    await setup(dut)
    for op in OPS:
        for a in EDGE_VALUES:
            for b in EDGE_VALUES:
                await check(dut, op, a, b)


@cocotb.test()
async def random_values(dut):
    await setup(dut)
    rng = random.Random(5)
    for _ in range(3000):
        op = rng.choice(OPS)
        # Small divisors too, so quotients are large.
        b = rng.getrandbits(rng.choice([32, 8, 1]))
        await check(dut, op, rng.getrandbits(32), b)


@cocotb.test()
async def latency(dut):
    await setup(dut)
    mul = await check(dut, "mul", 3, 4)
    div = await check(dut, "div", 100, 7)
    dut._log.info(f"multiply: done {mul} cycles after start, divide: {div} cycles")


def test_muldiv():
    run("muldiv", ["muldiv.sv"], "test_muldiv")
