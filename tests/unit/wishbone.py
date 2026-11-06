"""A minimal Wishbone master for testing slaves: drives stb/we/adr/dat_w/sel and waits for ack."""

from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge


class WishboneMaster:
    def __init__(self, dut, timeout=20):
        self.dut = dut
        self.timeout = timeout
        dut.wb_stb.value = 0
        dut.wb_we.value = 0
        dut.wb_adr.value = 0
        dut.wb_dat_w.value = 0
        dut.wb_sel.value = 0

    async def _access(self, addr, we, data, sel):
        dut = self.dut
        await FallingEdge(dut.clk)
        dut.wb_stb.value = 1
        dut.wb_we.value = we
        dut.wb_adr.value = addr
        dut.wb_dat_w.value = data
        dut.wb_sel.value = sel
        for _ in range(self.timeout):
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.wb_ack.value):
                value = int(dut.wb_dat_r.value)
                break
        else:
            raise AssertionError(f"no ack for access to {addr:#x}")
        await FallingEdge(dut.clk)
        dut.wb_stb.value = 0
        dut.wb_we.value = 0
        return value

    async def write(self, addr, data, sel=0xF):
        await self._access(addr, 1, data, sel)

    async def read(self, addr):
        return await self._access(addr, 0, 0, 0xF)
