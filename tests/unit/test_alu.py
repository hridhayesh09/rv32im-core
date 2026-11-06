import random

import cocotb
from cocotb.triggers import Timer

from rv_defs import *
from sim import run

EDGE_VALUES = [0, 1, 2, 31, 32, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF, 0x55555555, 0xAAAAAAAA]


def alu_model(op, a, b):
    sh = b & 31
    if op == ALU_ADD:
        return (a + b) & MASK32
    if op == ALU_SUB:
        return (a - b) & MASK32
    if op == ALU_SLL:
        return (a << sh) & MASK32
    if op == ALU_SLT:
        return int(signed32(a) < signed32(b))
    if op == ALU_SLTU:
        return int(a < b)
    if op == ALU_XOR:
        return a ^ b
    if op == ALU_SRL:
        return a >> sh
    if op == ALU_SRA:
        return (signed32(a) >> sh) & MASK32
    if op == ALU_OR:
        return a | b
    if op == ALU_AND:
        return a & b
    raise ValueError(op)


async def check(dut, op, a, b):
    dut.op.value = op
    dut.a.value = a
    dut.b.value = b
    await Timer(1, unit="ns")
    got = int(dut.y.value)
    exp = alu_model(op, a, b)
    assert got == exp, f"op={op} a={a:#010x} b={b:#010x}: got {got:#010x}, expected {exp:#010x}"


@cocotb.test()
async def edge_values(dut):
    """Every op on every pair of boundary values (overflow, sign bit, shift amounts 31/32)."""
    for op in ALU_OPS:
        for a in EDGE_VALUES:
            for b in EDGE_VALUES:
                await check(dut, op, a, b)


@cocotb.test()
async def random_values(dut):
    rng = random.Random(1)
    for _ in range(20000):
        await check(dut, rng.choice(ALU_OPS), rng.getrandbits(32), rng.getrandbits(32))


def test_alu():
    run("alu", ["alu.sv"], "test_alu")
