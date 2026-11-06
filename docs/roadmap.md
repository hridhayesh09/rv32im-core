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
2. Pipeline with branch/jump flush (predict not-taken, resolve in EX, flush 2 instructions when taken)
   and lockstep comparison against Spike (moved up from step 7, so every later step is checked by it).
   Test programs separate dependent instructions with NOPs.
3. Forwarding (EX/MEM→EX, MEM/WB→EX) and write-before-read in the register file.
4. Load-use stall (one bubble).
5. (merged into step 2)
6. Official riscv-tests rv32ui on a small custom `riscv_test.h`.
   `fence_i` is expected to fail with separate instruction/data memories; it is listed as excluded, with that reason.
7. (merged into step 2)
8. Random instruction tests: a Python generator of random instruction streams, each checked against Spike in lockstep.
9. M extension: multi-cycle multiply (2 extra cycles) and iterative divide (33 extra cycles) that stall EX; rv32um and lockstep.
10. `crt0.S`, `link.ld`, fibonacci and sort in C.
11. README architecture diagram and docs/notes.md.

**Done when:** rv32ui and rv32um pass, lockstep and random tests show zero mismatches, the C programs give the right results, all in CI.

## Stage 2: The computer (SoC) on the DE10-Lite

### Design decisions
- **Memory map**

  | Address | What |
  |---|---|
  | `0x0000_0000` | Boot ROM, 8 KB (reset address; holds the bootloader) |
  | `0x1000_0000` | UART |
  | `0x1000_1000` | Timer (64-bit cycle counter + compare) |
  | `0x1000_2000` | GPIO: LEDs, switches, buttons, 7-segment displays |
  | `0x4000_0000` | SDRAM, 64 MB (data: framebuffers, MNIST data, big arrays) |
  | `0x8000_0000` | On-chip RAM, 64 KB (programs: code, data, stack) |

  On-chip RAM stays at `0x8000_0000`, so every Stage 1 program and test links the same way.
- **Tightly coupled memory + a bus for everything else.** Boot ROM and on-chip RAM connect to the
  core directly, like ARM's TCMs: single-cycle, no stalls, and the RAM is dual-port (one port for
  fetch, one for data). Everything else (peripherals, SDRAM) sits on a **Wishbone** bus, which can
  take several cycles per access; the core's data port gets wait states for that.
- **Code runs from on-chip RAM, not SDRAM.** Fetching from SDRAM would cost several cycles per
  instruction without an instruction cache; the cache is a Stage 5 topic. SDRAM is for data.
- **The bootloader writes code through the data port into the same dual-port RAM that fetch
  reads**, so newly loaded code is visible to fetch (the FENCE.I problem from Stage 1 doesn't
  apply). FENCE.I becomes a pipeline flush, so the 2 instructions already fetched are refetched.
- **No interrupts yet:** drivers poll status registers. Interrupts and CSRs come when a
  peripheral needs them.

### Steps
1. Core data port with wait states: a slow access in WB freezes the pipeline until it completes.
   Tested by rerunning every lockstep test with random wait states injected.
2. Wishbone interconnect and peripherals: UART (TX/RX), timer, GPIO, each with unit tests.
3. SoC top: core + boot ROM + on-chip RAM + bus + peripherals, with a simulation test that runs C
   code printing over the UART.
4. SDRAM controller for the board's IS42S16320 chip (init, refresh, reads, writes), tested against
   a simulation model of the chip that checks timing rules.
5. C runtime: drivers for each peripheral, a small printf, and a UART bootloader in the boot ROM
   with a host-side upload script.
6. DE10-Lite top level with pin assignments, a Quartus compile (resource and timing reports; no
   board needed), and an early fit with the 16x16 array.
7. Board session (needs the board): checklist to flash, connect a terminal and run the demo, and a
   list of what to film.

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
