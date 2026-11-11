# rv32im-core

A complete computer built from the CPU up: a 5-stage RV32IM RISC-V CPU in
SystemVerilog, grown into a system-on-chip on the Terasic DE10-Lite (Intel MAX 10,
10M50) with SDRAM, UART, timer, GPIO, VGA graphics, and my INT8 systolic array
([edge-ml-accelerator](https://github.com/hridhayesh09/edge-ml-accelerator)) attached as an AI accelerator.

## Status

| Stage | What | Status |
|---|---|---|
| 0 | Toolchain, repo skeleton, CI | done |
| 1 | 5-stage RV32IM pipeline, riscv-tests, Spike lockstep, random tests, C programs | done |
| 2 | SoC: Wishbone bus, boot ROM, SDRAM, UART, timer, GPIO, UART bootloader | **runs on the DE10-Lite**: bootloader, hello, 64 MB SDRAM test ([board log](docs/results/board_2026-11-07.md)) |
| 3 | VGA framebuffer, graphics driver, a playable game | **runs on the DE10-Lite**: Snake playable on a real VGA monitor with the board's buttons |
| 4 | Systolic array accelerator, MNIST software vs accelerator | **runs on the DE10-Lite**: 16x16 NPU, MNIST bit-exact, 38.49x faster than software |
| 5 | I/D caches, branch predictor, CoreMark, measured tradeoffs | planned |
| stretch | Doom; OpenLane on Sky130 | planned |

The full plan for each stage is in [docs/roadmap.md](docs/roadmap.md).
Plain-English explanations of every part of the design, with interview questions,
are in [docs/notes.md](docs/notes.md).

## The CPU

```mermaid
flowchart LR
    subgraph IF[IF: fetch]
        PC[PC]
    end
    IMEM[(Instruction<br/>memory)]
    subgraph ID[ID: decode + register read]
        DEC[Decoder]
        RF[Register file<br/>write-before-read]
    end
    subgraph EX[EX: execute]
        FWD{{Forwarding<br/>muxes}}
        ALU[ALU]
        BR[Branch compare<br/>+ target]
        MD[Mul/Div unit<br/>2 / 33 cycles]
    end
    subgraph MEM[MEM]
        DMEM[(Data<br/>memory)]
    end
    subgraph WB[WB]
        LX[Load extend<br/>+ write back]
    end
    PC --> IMEM --> DEC
    DEC --> RF --> FWD
    FWD --> ALU --> DMEM
    FWD --> BR
    FWD --> MD --> DMEM
    DMEM --> LX
    LX -- write rd --> RF
    DMEM -. forward from MEM .-> FWD
    LX -. forward from WB .-> FWD
    BR -. taken: flush IF/ID, new PC .-> PC
```

- **5 stages**, in order: IF → ID → EX → MEM → WB, with synchronous-read memories (FPGA block RAM style).
- **Forwarding** from MEM and WB into EX, plus write-before-read in the register file.
- **Load-use stall:** one bubble when an instruction uses a load result right away.
- **Branches and jumps** resolve in EX; predict not-taken; a taken branch flushes 2 instructions.
- **Multiply/divide unit:** 2 extra cycles per multiply, 33 per divide; EX stalls until done.
- **Retire trace** (`rvfi_*`) used to compare every instruction against Spike.

## Results

All numbers come from `make test` (Verilator 5.036, Spike, GCC 13.2.0) unless noted.

**Verification**

| Check | Result |
|---|---|
| Unit tests: ALU, register file, decoder, mul/div unit against Python models | pass |
| Official riscv-tests rv32ui, in lockstep with Spike | **42 / 42** pass (misaligned accesses trap and are emulated by a handler, [how](docs/notes.md#stage-5-step-1-exceptions-and-csrs)) |
| Official riscv-tests rv32um, in lockstep with Spike | **8 / 8** pass (2,181 instructions compared) |
| Directed programs (forwarding, load-use, flush, mul/div, FENCE.I, traps and CSRs) in lockstep | 8 / 8 pass |
| Random RV32IM programs in lockstep (20 per CI run) | pass; a local 300-program run (`RANDOM_PROGRAMS=300 make test`) compared 140,887 instructions with 0 mismatches |
| C programs (GCC -O2) in lockstep | 3 / 3 pass |
| All of the above again with random wait states on every data access | pass |

**Performance in simulation** (cycles from reset until the program reports its result)

| Program | Instructions | Cycles | CPI |
|---|---|---|---|
| fib (recursive + iterative Fibonacci) | 176,516 | 203,389 | 1.152 |
| sort (quicksort of 256 numbers) | 29,513 | 38,312 | 1.298 |
| primes (trial division up to 2000) | 72,250 | 504,092 | 6.977 |

The ideal CPI for this pipeline is 1. The extra cycles come from taken branches (2 cycles each),
load-use stalls (1 cycle) and divides (33 cycles each), which is why `primes`, full of `%`, is
the slowest.

**MNIST on the board** (784 → 64 → 10, int8; [board log](docs/results/board_2026-11-07.md))

| | Images | Correct | Cycles per image | Time per image at 50 MHz |
|---|---|---|---|---|
| CPU only (software) | 10 | 10 | 856,963 | 17.1 ms |
| CPU + 16x16 NPU | 200 | 199 (99.5 %) | 22,263 | 445 us |

**Speedup: 38.49x**, and every logit of every image is bit-exact with the NumPy int8 model.

**FPGA build** (Quartus Prime Lite 25.1, DE10-Lite / 10M50, whole SoC: CPU, SDRAM, VGA, 16x16 NPU)

| Logic elements | Memory bits | 9-bit multipliers | Fmax (slow, 85 °C) | Setup slack at 50 MHz |
|---|---|---|---|---|
| 31,762 (64 %) | 1,162,824 (69 %), 165 / 182 M9K | 136 (47 %) | 55.88 MHz | +2.103 ns |

**Snake on the CPU** (frame captured from the simulated VGA monitor; [how it's tested](docs/notes.md#stage-3-graphics))

![Snake in simulation](docs/images/snake_sim.png)

## Getting started

Install the tools with [docs/setup.md](docs/setup.md), then:

```bash
make check-tools   # print every tool's version
make test          # all unit, ISA, random and C-program tests
```

## Repo layout

```
rtl/      SystemVerilog: core.sv (pipeline), alu, regfile, decoder, muldiv, dpram, wb_* peripherals
tb/       Verilator testbench top
tests/    unit/ (cocotb unit tests), core/ (lockstep runner, riscv-tests, random, C programs),
          asm/ (directed assembly tests), env/ (riscv-tests environment), riscv-tests/ (submodule)
sw/       crt0.S, link.ld, C programs
docs/     roadmap, setup, notes
```
