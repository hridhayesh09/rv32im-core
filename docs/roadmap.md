# Roadmap

Each stage starts with a written plan that is approved before any code is written.
Each step inside a stage must pass its tests before the next one starts.
Every number reported comes from an actual run.

## Stage 0: Toolchain and skeleton

1. Install WSL2 (Ubuntu 24.04), Verilator, the RISC-V GCC toolchain, Spike, cocotb ([setup.md](setup.md)).
2. Repo skeleton and `make check-tools`.
3. GitHub Actions CI that installs (and caches) the tools.

**Done when:** CI runs one trivial cocotb test on Verilator and passes.

## Stage 1: 5-stage RV32IM pipeline (simulation only)

1. ALU, register file, decoder, with cocotb unit tests against a Python model.
2. Pipeline with no hazard handling; test programs separate dependent instructions with NOPs.
3. Forwarding (EX/MEM→EX, MEM/WB→EX) and write-before-read in the register file.
4. Load-use stall (one bubble).
5. Branch/jump flush: predict not-taken, resolve in EX, flush 2 instructions when taken.
6. Official riscv-tests rv32ui on a small custom `riscv_test.h`.
   `fence_i` is expected to fail with separate instruction/data memories; it is listed as excluded, with that reason.
7. Retire trace port and lockstep comparison against Spike `--log-commits`
   (PC, register writes, memory writes at every retired instruction).
8. Random instruction tests: a Python generator of random instruction streams, each checked against Spike in lockstep.
9. M extension: pipelined multiply, iterative 32-cycle divide that stalls the pipeline; rv32um and lockstep.
10. `crt0.S`, `link.ld`, fibonacci and sort in C.
11. README architecture diagram and docs/notes.md.

**Done when:** rv32ui and rv32um pass, lockstep and random tests show zero mismatches, the C programs give the right results, all in CI.

## Stage 2: The computer (SoC) on the DE10-Lite

- Wishbone bus connecting the CPU to memory and peripherals.
- Boot ROM in on-chip memory; the board's 64 MB SDRAM as main memory through an SDRAM controller
  (tested in simulation against a model of the board's SDRAM chip that checks its timing rules).
- Memory-mapped UART (printf to a terminal), timer, GPIO (LEDs, switches, buttons).
- UART bootloader: load and run C programs without rebuilding the FPGA.
- Bare-metal C runtime and a driver for each peripheral.
- An early Quartus fit of CPU + SoC + 16x16 array to check logic, DSP multipliers and on-chip memory.
- Bring-up on the real board with a demo that prints to a terminal.
- A list of what to film for the demo video.

## Stage 3: Graphics

- VGA output with a framebuffer: on-chip at low resolution (e.g. 320x240) vs in SDRAM, with the tradeoff explained.
- Simulation saves frames as PNGs, so a GIF can be made without the board.
- A simple graphics driver in C.
- A playable game (Snake or Tetris) controlled with the board's buttons or over UART.
- A list of what to film for the demo video.

## Stage 4: AI accelerator

- Attach the 16x16 systolic array from edge-ml-accelerator, as a coprocessor through custom
  instructions or as a memory-mapped bus device (the choice and the reason are written up first).
- Keep 16x16 unless Quartus says it does not fit; then decide what to shrink.
- MNIST in C on the CPU: software only vs with the accelerator, bit-exact check, measured speedup.
- A list of what to film for the demo video.

## Stage 5: Architect-level tradeoffs

- I and D caches, branch predictor.
- Measured tradeoffs: cache size vs IPC, predictor vs no predictor, area cost; CoreMark.

## Stretch

- Doom on the CPU.
- OpenLane on Sky130 for timing, area and power.

## What needs the board

Stages 0, 1, 5 and OpenLane need no board. In Stages 2–4 everything is built and checked in
simulation and Quartus first; only the final bring-up and filming need the board. Each of those
stages ends with a short checklist for the board session.
