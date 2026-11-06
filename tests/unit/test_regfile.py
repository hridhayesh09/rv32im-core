import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from sim import run


class RegfileModel:
    def __init__(self):
        self.regs = [0] * 32

    def read(self, addr, we, rd, data):
        if addr == 0:
            return 0
        if we and rd == addr:
            return data  # write-before-read
        return self.regs[addr]

    def write(self, we, rd, data):
        if we and rd != 0:
            self.regs[rd] = data


async def cycle(dut, model, rs1, rs2, we, rd, data):
    """Drive one cycle's inputs, check both read ports, then clock the write in."""
    await FallingEdge(dut.clk)
    dut.rs1_addr.value = rs1
    dut.rs2_addr.value = rs2
    dut.we.value = we
    dut.rd_addr.value = rd
    dut.rd_data.value = data
    await Timer(1, unit="ns")
    for port, addr in (("rs1", rs1), ("rs2", rs2)):
        got = int(getattr(dut, f"{port}_data").value)
        exp = model.read(addr, we, rd, data)
        assert got == exp, f"{port}=x{addr} (we={we} rd=x{rd}): got {got:#010x}, expected {exp:#010x}"
    await RisingEdge(dut.clk)
    model.write(we, rd, data)


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    model = RegfileModel()
    # Registers have no reset, so give every one a known value first.
    for r in range(1, 32):
        await cycle(dut, model, 0, 0, 1, r, 0)
    return model


@cocotb.test()
async def x0_stays_zero(dut):
    model = await start(dut)
    await cycle(dut, model, 0, 0, 1, 0, 0xDEADBEEF)  # write to x0 is ignored...
    await cycle(dut, model, 0, 0, 0, 0, 0)           # ...and x0 still reads 0 next cycle


@cocotb.test()
async def write_before_read(dut):
    model = await start(dut)
    await cycle(dut, model, 5, 5, 1, 5, 0x12345678)  # same-cycle read sees the new value
    await cycle(dut, model, 5, 6, 0, 0, 0)           # and it was stored


@cocotb.test()
async def random_traffic(dut):
    model = await start(dut)
    rng = random.Random(2)
    for _ in range(20000):
        rd = rng.randrange(32)
        # Read the register being written often, to exercise the bypass.
        rs1 = rd if rng.random() < 0.25 else rng.randrange(32)
        rs2 = rd if rng.random() < 0.25 else rng.randrange(32)
        await cycle(dut, model, rs1, rs2, rng.getrandbits(1), rd, rng.getrandbits(32))


def test_regfile():
    run("regfile", ["regfile.sv"], "test_regfile")
