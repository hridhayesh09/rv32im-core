"""VGA block: write pixels and a palette colour over Wishbone, let the simulated monitor
(tb/vga_capture.sv) capture frames, and check the image and the sync timing."""

import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from sim import ROOT, run
from wishbone import WishboneMaster

sys.path.insert(0, str(ROOT / "tools"))
from ppm import pixel, ppm_to_png, read_ppm  # noqa: E402

FB = 0x20000000
REGS = 0x10003000
FRAMES = ROOT / "build" / "vga_unit"
DEFAULT_PALETTE = [0x000, 0x00A, 0x0A0, 0x0AA, 0xA00, 0xA0A, 0xA50, 0xAAA,
                   0x555, 0x55F, 0x5F5, 0x5FF, 0xF55, 0xF5F, 0xFF5, 0xFFF]


def rgb(colour12):
    return tuple(((colour12 >> s) & 0xF) * 17 for s in (8, 4, 0))


@cocotb.test()
async def draws_framebuffer(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    bus = WishboneMaster(dut)
    dut.rst.value = 1
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0

    # Some pixels: corners, a short line, and every colour along row 120.
    pixels = {(0, 0): 15, (319, 0): 12, (0, 239): 10, (319, 239): 9, (5, 5): 1}
    for x in range(20, 60):
        pixels[(x, 100)] = 4
    for c in range(16):
        pixels[(100 + c, 120)] = c
    for (x, y), c in pixels.items():
        addr = FB + y * 320 + x
        await bus.write(addr, c << (8 * (addr & 3)), sel=1 << (addr & 3))   # like a CPU sb
    for (x, y), c in list(pixels.items())[:6]:
        assert await bus.read(FB + y * 320 + x) & 0xF == c, f"read back ({x},{y})"

    palette = list(DEFAULT_PALETTE)
    palette[1] = 0x123
    await bus.write(REGS + 4, 0x123)
    assert await bus.read(REGS + 4) == 0x123

    while int(dut.frames.value) < 3:
        await ClockCycles(dut.clk, 10000)
    assert int(dut.timing_errors.value) == 0
    frame0 = await bus.read(REGS + 0x44)
    assert frame0 >= 2, "FRAME counter not counting"

    width, height, rows = read_ppm(FRAMES / "frame001.ppm")
    assert (width, height) == (640, 480)
    for (x, y), c in pixels.items():
        for dx in (0, 1):
            for dy in (0, 1):   # each framebuffer pixel covers 2x2 screen pixels
                got = pixel(rows, 2 * x + dx, 2 * y + dy)
                assert got == rgb(palette[c]), f"({x},{y}) colour {c}: screen shows {got}"
    assert pixel(rows, 300, 300) == rgb(palette[0])   # untouched: colour 0
    ppm_to_png(FRAMES / "frame001.ppm")


FRAMES8 = ROOT / "build" / "vga_unit8"


@cocotb.test()
async def draws_8bit(dut):
    """MODE8: 320x200 framebuffer, 8 bits per pixel (write only), 256-entry palette, 32-bit
    writes; the picture is 640x400 between black bars of 40 lines."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    bus = WishboneMaster(dut)
    dut.rst.value = 1
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0

    palette = {i: (i * 2654435761 >> 8) & 0xFFF for i in range(256)}
    for i, c in palette.items():
        await bus.write(REGS + 0x400 + 4 * i, c)

    # Row 0: colours 0..255 then 256..319 again (4 pixels per word write); a few byte writes.
    row0 = [x & 0xFF for x in range(320)]
    for x in range(0, 320, 4):
        await bus.write(FB + x, row0[x] | row0[x + 1] << 8 | row0[x + 2] << 16 | row0[x + 3] << 24)
    pixels = {(x, 0): row0[x] for x in range(320)}
    for (x, y), c in {(0, 199): 0x80, (319, 199): 0xFF, (160, 100): 0x42, (7, 50): 0x99}.items():
        addr = FB + y * 320 + x
        await bus.write(addr, c << (8 * (addr & 3)), sel=1 << (addr & 3))
        pixels[(x, y)] = c

    while int(dut.frames.value) < 3:
        await ClockCycles(dut.clk, 10000)
    assert int(dut.timing_errors.value) == 0

    width, height, rows = read_ppm(FRAMES8 / "frame001.ppm")
    assert (width, height) == (640, 480)
    for (x, y), c in pixels.items():
        for dx in (0, 1):
            for dy in (0, 1):
                got = pixel(rows, 2 * x + dx, 40 + 2 * y + dy)
                assert got == rgb(palette[c]), f"({x},{y}) colour {c}: screen shows {got}"
    for y in (0, 39, 440, 479):   # the bars
        assert pixel(rows, 320, y) == (0, 0, 0), f"line {y} not black"
    ppm_to_png(FRAMES8 / "frame001.ppm")


def test_vga():
    FRAMES.mkdir(parents=True, exist_ok=True)
    run("tb_vga", ["fb_ram.sv", "fb8_ram.sv", "wb_vga.sv", ROOT / "tb" / "vga_capture.sv",
                   ROOT / "tb" / "tb_vga.sv"],
        "test_vga", testcase="draws_framebuffer", plusargs=[f"+vga_dump={FRAMES}/frame"])


def test_vga_8bit():
    FRAMES8.mkdir(parents=True, exist_ok=True)
    run("tb_vga", ["fb_ram.sv", "fb8_ram.sv", "wb_vga.sv", ROOT / "tb" / "vga_capture.sv",
                   ROOT / "tb" / "tb_vga.sv"],
        "test_vga", testcase="draws_8bit", plusargs=[f"+vga_dump={FRAMES8}/frame"],
        parameters={"MODE8": 1}, tag="_mode8")
