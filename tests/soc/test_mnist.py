"""MNIST on the whole SoC in simulation: the model and 20 test images are preloaded into the
SDRAM model; sw/soc/mnist.c runs 2 images in software and 20 on the NPU, and every logit must
equal the NumPy int8 model's."""

import subprocess
from pathlib import Path

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from soc_sim import ROOT, SW, build_bootrom, build_program, build_soc, uart_monitor

HERE = Path(__file__).resolve().parent
N_IMAGES = 20


@cocotb.test()
async def mnist(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.rxd.value = 1
    dut.sw.value = 0
    dut.key_n.value = 0b11
    dut.rst.value = 1
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0
    received = []
    cocotb.start_soon(uart_monitor(dut, received))
    for _ in range(20_000):
        await ClockCycles(dut.clk, 1000)
        if b"DONE" in bytes(received):
            break
    text = bytes(received).decode(errors="replace")
    for line in text.splitlines():
        dut._log.info(f"uart: {line}")
    assert "MNIST PASS: all logits bit-exact" in text
    assert int(dut.sdram_violations.value) == 0


@pytest.fixture(scope="module")
def soc_runner():
    return build_soc()


def test_mnist(soc_runner):
    # Its own file name, so the board's 200-image build/mnist/mnist_blob.bin isn't replaced.
    subprocess.run(["python3", str(ROOT / "tools" / "export_mnist.py"), str(N_IMAGES),
                    f"mnist_blob_{N_IMAGES}"], check=True)
    blob = ROOT / "build" / "mnist" / f"mnist_blob_{N_IMAGES}.hex"
    bootrom = build_bootrom(SW / "boot" / "jump_to_ram.S")
    program = build_program(SW / "soc" / "mnist.c", extra_flags=["-DN_SOFTWARE=2", f"-DN_NPU={N_IMAGES}"],
                            name="soc-mnist-test")
    soc_runner.test(
        hdl_toplevel="tb_soc",
        test_module="test_mnist",
        testcase="mnist",
        test_dir=HERE,
        plusargs=[f"+bootrom={bootrom}", f"+program={program}", f"+sdram_init={blob}"],
        results_xml=str(program.with_suffix(".result.xml")),
    )
