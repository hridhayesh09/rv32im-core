# rv32im-core

A complete computer built from the CPU up: a 5-stage RV32IM RISC-V CPU in
SystemVerilog, grown into a system-on-chip on the Terasic DE10-Lite (Intel MAX 10,
10M50) with SDRAM, UART, timer, GPIO, VGA graphics, and my INT8 systolic array
([edge-ml-accelerator](https://github.com/hridhayesh09/edge-ml-accelerator)) attached as an AI accelerator.

## Status

| Stage | What | Status |
|---|---|---|
| 0 | Toolchain, repo skeleton, CI | done |
| 1 | 5-stage RV32IM pipeline, riscv-tests, Spike lockstep, random tests, C programs | in progress: RV32I pipeline with forwarding, load-use stall and branch flush; 40/42 official rv32ui tests pass in lockstep with Spike (2 excluded, see notes); random programs match Spike |
| 2 | SoC: Wishbone bus, boot ROM, SDRAM, UART, timer, GPIO, UART bootloader | planned |
| 3 | VGA framebuffer, graphics driver, a playable game | planned |
| 4 | Systolic array accelerator, MNIST software vs accelerator | planned |
| 5 | I/D caches, branch predictor, CoreMark, measured tradeoffs | planned |
| stretch | Doom; OpenLane on Sky130 | planned |

The full plan for each stage is in [docs/roadmap.md](docs/roadmap.md).
Plain-English explanations of every part of the design, with interview questions,
are in [docs/notes.md](docs/notes.md).

## Results

None yet. Every number added here will come from an actual run, with the command
that produced it.

## Getting started

Install the tools with [docs/setup.md](docs/setup.md), then check them:

```bash
make check-tools
```

## Repo layout

```
rtl/      SystemVerilog source for the CPU and SoC
tb/       Verilator testbench top and trace output
tests/    cocotb unit tests, assembly tests, riscv-tests, lockstep, random tests
sw/       startup code, linker script, drivers, C programs
docs/     roadmap, setup, notes
```
