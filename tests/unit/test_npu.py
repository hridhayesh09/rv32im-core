"""NPU unit tests: matrix products through the Wishbone interface, against NumPy."""

import random

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from sim import ROOT, run
from wishbone import WishboneMaster

REGS, A_BUF, C_BUF = 0x10004000, 0x30000000, 0x30010000
CTRL, STATUS, A_BASE, A_STRIDE, C_BASE, C_STRIDE, COUNT, W_DATA, W_RESET, CYCLES = (
    0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x20, 0x24, 0x28)


def words(row_i8):
    """16 int8 -> 4 little-endian 32-bit words."""
    b = np.asarray(row_i8, dtype=np.int8).tobytes()
    return [int.from_bytes(b[4 * k: 4 * k + 4], "little") for k in range(4)]


class Npu:
    def __init__(self, bus):
        self.bus = bus

    async def reg(self, offset, value=None):
        if value is None:
            return await self.bus.read(REGS + offset)
        await self.bus.write(REGS + offset, value)

    async def load_weights(self, w):            # w: 16x16 int8, w[k][n]
        await self.reg(W_RESET, 0)
        for k in range(16):
            for word in words(w[k]):
                await self.reg(W_DATA, word)

    async def write_a(self, row, values):        # 16 int8
        for k, word in enumerate(words(values)):
            await self.bus.write(A_BUF + row * 16 + k * 4, word)

    async def read_c(self, row):
        out = [await self.bus.read(C_BUF + row * 64 + j * 4) for j in range(16)]
        return [v - (1 << 32) if v & 0x80000000 else v for v in out]

    async def matmul(self, count, a_base=0, a_stride=1, c_base=0, c_stride=1, accumulate=False):
        await self.reg(A_BASE, a_base)
        await self.reg(A_STRIDE, a_stride)
        await self.reg(C_BASE, c_base)
        await self.reg(C_STRIDE, c_stride)
        await self.reg(COUNT, count)
        await self.reg(CTRL, 1 | (2 if accumulate else 0))
        while await self.reg(STATUS) & 1:
            pass
        return await self.reg(CYCLES)


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    bus = WishboneMaster(dut)
    dut.rst.value = 1
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0
    return Npu(bus)


@cocotb.test()
async def one_tile(dut):
    """C = A x W for 20 rows, one 16x16 tile, random int8 including the extremes."""
    npu = await setup(dut)
    rng = np.random.default_rng(1)
    a = rng.integers(-128, 128, size=(20, 16), dtype=np.int8)
    w = rng.integers(-128, 128, size=(16, 16), dtype=np.int8)
    a[0, :] = -128
    w[:, 0] = -128            # largest possible sum: 16 * (-128)(-128) = 262144
    a[1, :] = 127
    for m in range(20):
        await npu.write_a(m, a[m])
    await npu.load_weights(w)
    cycles = await npu.matmul(20)
    expected = a.astype(np.int64) @ w.astype(np.int64)
    for m in range(20):
        assert await npu.read_c(m) == list(expected[m]), f"row {m}"
    dut._log.info(f"20 rows in {cycles} cycles")


@cocotb.test()
async def accumulate_over_k(dut):
    """C = A x W with K = 48: three weight tiles, the first overwrites C and the rest add to it.
    A is stored the way MNIST uses it: row m*3 + kt holds A[m, 16*kt : 16*kt + 16]."""
    npu = await setup(dut)
    rng = np.random.default_rng(2)
    m_rows, k_tiles = 12, 3
    a = rng.integers(-128, 128, size=(m_rows, 16 * k_tiles), dtype=np.int8)
    w = rng.integers(-128, 128, size=(16 * k_tiles, 16), dtype=np.int8)
    for m in range(m_rows):
        for kt in range(k_tiles):
            await npu.write_a(m * k_tiles + kt, a[m, 16 * kt: 16 * kt + 16])
    for kt in range(k_tiles):
        await npu.load_weights(w[16 * kt: 16 * kt + 16])
        await npu.matmul(m_rows, a_base=kt, a_stride=k_tiles, c_base=5, c_stride=2,
                         accumulate=kt > 0)
    expected = a.astype(np.int64) @ w.astype(np.int64)
    for m in range(m_rows):
        assert await npu.read_c(5 + 2 * m) == list(expected[m]), f"row {m}"


@cocotb.test()
async def random_products(dut):
    """Random sizes, strides and bases; each product checked against NumPy."""
    npu = await setup(dut)
    rng = np.random.default_rng(3)
    pick = random.Random(3)
    for trial in range(6):
        count = pick.randint(1, 40)
        a_base, a_stride = pick.randint(0, 100), pick.randint(1, 5)
        c_base, c_stride = pick.randint(0, 40), pick.randint(1, 3)
        a = rng.integers(-128, 128, size=(count, 16), dtype=np.int8)
        w = rng.integers(-128, 128, size=(16, 16), dtype=np.int8)
        for m in range(count):
            await npu.write_a(a_base + m * a_stride, a[m])
        await npu.load_weights(w)
        await npu.matmul(count, a_base, a_stride, c_base, c_stride)
        expected = a.astype(np.int64) @ w.astype(np.int64)
        for m in range(count):
            assert await npu.read_c(c_base + m * c_stride) == list(expected[m]), \
                f"trial {trial}, row {m}"


def test_npu():
    npu = ROOT / "rtl" / "npu"
    run("wb_npu", [npu / "lint.vlt", npu / "pe.v", npu / "systolic_array.v", npu / "sdp_ram.sv",
                   npu / "wb_npu.sv"],
        "test_npu")
