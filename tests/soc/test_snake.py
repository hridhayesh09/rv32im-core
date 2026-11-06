"""Snake on the whole SoC in simulation: start it over the UART, steer it, crash it into a wall,
and check the moves, the result and the picture on the (simulated) VGA monitor.

The test build moves every 1 ms instead of 120 ms (simulation runs about 250,000 cycles per
second) and prints the head position after every move.
"""

import shutil
import sys
from pathlib import Path

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from soc_sim import ROOT, SW, build_bootrom, build_program, build_soc, uart_monitor, uart_send

sys.path.insert(0, str(ROOT / "tools"))
from ppm import pixel, ppm_to_png, read_ppm  # noqa: E402

HERE = Path(__file__).resolve().parent
FRAMES = ROOT / "build" / "snake_frames"
CELL = 8


def text(received):
    return bytes(received).decode(errors="replace")


async def wait_for(dut, received, marker, max_cycles):
    for _ in range(max_cycles // 1000):
        if marker in text(received):
            return
        await ClockCycles(dut.clk, 1000)
    raise AssertionError(f"never saw {marker!r}; got:\n{text(received)}")


@cocotb.test()
async def snake_game(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.rxd.value = 1
    dut.sw.value = 0
    dut.key_n.value = 0b11
    dut.rst.value = 1
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0
    received = []
    cocotb.start_soon(uart_monitor(dut, received))

    await wait_for(dut, received, "SNAKE ready", 3_000_000)
    await uart_send(dut, b"d")                         # start
    await wait_for(dut, received, "head 12 15", 3_000_000)
    await uart_send(dut, b"s")                         # turn down
    await wait_for(dut, received, "DONE", 5_000_000)

    moves = [tuple(map(int, line.split()[1:])) for line in text(received).splitlines()
             if line.startswith("head ")]
    for line in text(received).splitlines():
        dut._log.info(f"uart: {line}")

    # Right along row 15 from (8,15), turn down at some column (the 's' arrives within a move),
    # then straight down to the last free row, 28: the wall is row 29.
    assert moves[0] == (8, 15)
    turn = next(i for i in range(1, len(moves)) if moves[i][1] != 15)
    for i in range(1, len(moves)):
        dx, dy = moves[i][0] - moves[i - 1][0], moves[i][1] - moves[i - 1][1]
        assert (dx, dy) == ((1, 0) if i < turn else (0, 1)), f"move {i}: {moves[i - 1]} -> {moves[i]}"
    assert moves[-1][1] == 28, "should crash into the bottom wall after row 28"
    assert "GAME OVER" in text(received)

    # Let two more frames be drawn, then check the picture.
    seen = int(dut.vga_frames.value)
    while int(dut.vga_frames.value) < seen + 2:
        await ClockCycles(dut.clk, 10000)
    assert int(dut.vga_timing_errors.value) == 0
    last = FRAMES / f"frame{int(dut.vga_frames.value) - 1:03d}.ppm"
    _, _, rows = read_ppm(last)

    def cell_colour(cx, cy):           # the middle of a cell, on screen (2x scale)
        return pixel(rows, 2 * (cx * CELL + 4), 2 * (cy * CELL + 4))

    dark_grey, light_green, green = (85, 85, 85), (85, 255, 85), (0, 170, 0)
    assert cell_colour(0, 10) == dark_grey             # left wall
    assert cell_colour(*moves[-1]) == light_green      # the head where it crashed
    assert cell_colour(*moves[-2]) == green            # body right behind it
    yellow = (255, 255, 85)
    game_over_area = [pixel(rows, x, y) for x in range(100, 540, 2) for y in range(200, 242, 2)]
    assert yellow in game_over_area, "GAME OVER text not on screen"

    png = ppm_to_png(last)
    shutil.copy(png, ROOT / "build" / "snake_screenshot.png")
    dut._log.info(f"{len(moves)} moves, screenshot from {last.name}")


@pytest.fixture(scope="module")
def soc_runner():
    return build_soc()


def test_snake(soc_runner):
    if FRAMES.exists():
        shutil.rmtree(FRAMES)
    FRAMES.mkdir(parents=True)
    bootrom = build_bootrom(SW / "boot" / "jump_to_ram.S")
    program = build_program(SW / "soc" / "snake.c", extra_flags=["-DTRACE", "-DSTEP_US=1000"],
                            name="soc-snake-test")
    soc_runner.test(
        hdl_toplevel="tb_soc",
        test_module="test_snake",
        testcase="snake_game",
        test_dir=HERE,
        plusargs=[f"+bootrom={bootrom}", f"+program={program}", f"+vga_dump={FRAMES}/frame"],
        results_xml=str(program.with_suffix(".result.xml")),
    )
