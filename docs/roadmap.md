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

### Framebuffer decision: on-chip, 320x240, 16 colours
The numbers that decide it (block RAMs on the 10M50: 182 M9Ks of 9 Kbit):

| Option | Block RAM | Notes |
|---|---|---|
| On-chip, 320x240, 8 bits/pixel | 75 M9K | 256 colours; too much RAM |
| **On-chip, 320x240, 4 bits/pixel (16-colour palette)** | **38 M9K** | **chosen** |
| SDRAM, any size | ~2 M9K (line buffer) | needs a second SDRAM master + arbiter; CPU pixel writes ~11 cycles; untested board SDRAM in the video path |

- **On-chip** is simple and deterministic: the VGA side reads its own port of a dual-port RAM
  every pixel, the CPU writes the other port, no contention. It costs block RAM.
- **SDRAM** costs almost no block RAM, but the display must fetch each line ahead into a line
  buffer while competing with the CPU and refresh for the SDRAM, and every CPU pixel write goes
  through the slow SDRAM path.
- 320x240 is doubled to 640x480 on the monitor; 16 colours from a programmable palette of the
  board's 12-bit colours (4 bits per channel on the DE10-Lite's VGA DAC) is plenty for games.

**Consequence for Stage 4 (written down now, not discovered later):** SoC (72 M9K) + framebuffer
(38) = 110 of 182, leaving 72. The accelerator build in edge-ml-accelerator uses 169 M9K, most of
it a 51 KB weight ROM. So Stage 4 can't copy that build as it is. The options: weights in SDRAM
(loaded by the CPU) instead of ROM, a smaller CPU RAM (64 → 32 KB frees 32 M9K), or the
framebuffer moved to SDRAM. Decided at the start of Stage 4, with real Quartus numbers.

### Steps
1. VGA timing (640x480 at 60 Hz from a 25 MHz pixel enable), framebuffer (CPU sees one byte per
   pixel at `0x2000_0000`), palette and status registers (`0x1000_3000`), with unit tests.
2. Integrate into the SoC; the simulation saves frames as PNG images.
3. Graphics driver in C (pixels, rectangles, text, waiting for vertical blank).
4. A playable game (Snake), controlled with the board's buttons or over the UART; a GIF from
   simulation for the README.
5. Quartus fit and timing; board checklist and what to film.

## Stage 4: AI accelerator

### Interface decision: memory-mapped accelerator ("NPU") with local buffers
The 16x16 array (`systolic_array.v` and `pe.v` from edge-ml-accelerator, unchanged) consumes one
16-byte activation row per clock and produces sixteen 32-bit sums per clock.

| Option | Data rate into the array | Cost |
|---|---|---|
| Custom instructions (custom-0/1) | at most 4 bytes per instruction (one register): the array idles >90 % | changes to the decoder, hazards and stalls for long operations, a Spike extension for lockstep |
| **Memory-mapped device with local buffers** | **16 bytes per clock** from its own buffer, once loaded | buffer RAM (block RAM), a small sequencer |

**Chosen: memory-mapped.** The CPU writes activations and weights into the accelerator's local
buffers over the bus, then starts a whole tile computation with one register write; a sequencer
streams the rows through the array at one per clock and accumulates the results in a local result
buffer. Custom instructions pay off for small, frequent operations on register data (like a
4-way int8 dot product), not for 16x16 tiles.

### Memory budget (182 M9K)
- SoC with VGA: 110. Left: 72.
- Activation buffer: 1024 rows x 16 bytes (16 KB): 16 M9K. Result buffer: 256 rows x 16 x 32 bits
  (16 KB): 16 M9K. Total 32, leaving 40 spare.
- The MNIST weights (51 KB) don't stay on chip (edge-ml-accelerator's weight ROM was most of its
  169 M9K): they live in **SDRAM**, and the CPU loads each 16x16 weight tile into the array
  before using it. The test images also live in SDRAM. Both are loaded with an extended
  bootloader (load data to any address).
- DSP blocks: the array puts 128 PEs in DSP blocks (one per block) and 128 in logic; the CPU's
  multiplier needs 4 more blocks: 132 of 144.

### The workload: MNIST 784 → 64 → 10 (int8), bit-exact with edge-ml-accelerator's NumPy model
- Software only: the whole network in C on the CPU (int8 x int8 → int32, requantize
  `(acc * 9710 + 2^23) >> 24` clipped to 0..127, layer 2, argmax).
- With the NPU: layer 1 as 49 x 4 tiles accumulated in the result buffer, requantize on the CPU,
  layer 2 as 4 x 1 tiles; batches of images share each weight tile.
- Checked: both paths give the same logits for every image, equal to the NumPy reference; speedup
  measured with the timer, in simulation and on the board.

### Steps
1. NPU block (`wb_npu`): weight loading, activation/result buffers, sequencer, registers; unit
   tests against NumPy matrix products (random and edge-case matrices, accumulate mode).
2. Early Quartus fit of SoC + NPU (16x16): logic, DSP blocks, block RAM, timing. Shrink only if it
   doesn't fit.
3. Bootloader: load data to any address (SDRAM). Model export: weights and test images.
4. MNIST in C, software and NPU versions; SoC simulation test: same logits as NumPy, speedup.
5. Board checklist and what to film.

## Stage 5: CPU microarchitecture

Order matters: Doom needs Stage 5 (its code, ~0.5-1 MB, and data, ~10 MB, only fit in SDRAM, and
running from SDRAM without an instruction cache costs ~14 cycles per instruction).

1. **Exceptions and CSRs (Zicsr, machine mode):** traps for illegal instructions, ECALL, EBREAK
   and misaligned loads/stores/jumps, taken precisely in EX; `mret`; `mstatus`, `mtvec`, `mepc`,
   `mcause`, `mtval`, `mscratch`, `misa`, `mhartid`, `mcycle`, `minstret`. Misaligned accesses are
   emulated by a trap handler (as firmware does on real RISC-V systems), so `ma_data` passes:
   rv32ui 42/42. Spike traps the same way, so lockstep covers trap entry, handler and `mret`.
2. **Performance counters** (`mhpmcounter3+`, standard CSRs readable from C): I/D cache hits and
   misses, branch mispredicts, stall cycles.
3. **SDRAM burst reads** of whole cache lines (checked against the SDRAM chip model).
4. **I-cache:** configurable size, direct-mapped or 2-way (LRU), code running from SDRAM.
5. **D-cache: write-back, write-allocate.** SDRAM writes cost ~11 cycles each; write-through would
   send every store there. FENCE.I writes back dirty lines and invalidates the I-cache, so code
   written as data (the bootloader, a program loader) then runs correctly.
6. **Branch prediction:** BTB + 2-bit bimodal, then gshare, then a return address stack.
7. **CoreMark** (EEMBC, Apache-2.0); official-format scores only from board runs of 10 s or more.
8. **Tradeoff table** from real runs: cache size and associativity vs IPC and CoreMark/MHz,
   predictor vs mispredict rate, and the LE/M9K cost of each (Quartus).

Build configurations: a CPU-only build (no NPU, frees ~55 M9K) for the experiments and Doom; the
full SoC keeps the NPU and gets caches only if Quartus says they fit. Every existing test keeps
passing with the caches on: riscv-tests, Spike lockstep and random programs run with the program
in slow memory behind the caches.

## Doom
1. picolibc as the C library; `malloc` and an in-memory file system on SDRAM.
2. An 8-bit, 256-colour framebuffer at Doom's 320x200 (CPU-only build), Doom's palette mapped to
   the board's 12-bit colours.
3. `doomgeneric` (GPL-2.0, submodule): video, ticks, sleep and key callbacks.
4. A 2 Mbaud bootloader mode for the ~4 MB WAD; `tools/doom_keys.py` sends key presses/releases.
5. Freedoom (BSD) for tests; DOOM1.WAD (shareware, not committed) optionally for the demo.
6. Frame rate measured on the board.

## Stage 6: ASIC flow
1. Technology-independent memories: one wrapper with an FPGA version (altsyncram) and an ASIC
   version (Sky130 SRAM macros or register-based RAM).
2. OpenLane 2 on Sky130: the core plus small caches to GDS, clean DRC and LVS.
3. Area, maximum frequency (STA) and estimated power from the actual reports.
4. Gate-level simulation of the final netlist on riscv-tests.
5. A layout screenshot in the README.

## Stretch
- Out-of-order execution.

## What needs the board

Stages 0, 1, 5 and OpenLane need no board. In Stages 2–4 everything is built and checked in
simulation and Quartus first; only the final bring-up and filming need the board. Each of those
stages ends with a short checklist for the board session.
