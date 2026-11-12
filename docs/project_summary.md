# rv32im-core: project summary (for a new Claude chat)

Paste this into a new conversation to give it the full context.

## Who and what
I'm a Computer Engineering junior targeting RTL, CPU, DV and FPGA internships. This project is a
complete computer built from the CPU up: my own RISC-V CPU, a system-on-chip around it on a Terasic
DE10-Lite FPGA board (Intel MAX 10, 10M50), real software on it (CoreMark, MNIST on an accelerator,
Snake, Doom), and the CPU taken to a chip layout in SkyWater 130 nm with OpenLane.

- Repo: github.com/hridhayesh09/rv32im-core (public), local at C:\Users\hridh\rv32im-core.
- Tools: SystemVerilog, Verilator 5.036 + cocotb 2.1 (simulation), Spike (reference ISA
  simulator), GCC 13.2 riscv64-unknown-elf, Quartus Prime Lite 25.1, OpenLane 2.3.10 via Nix,
  Icarus Verilog; WSL Ubuntu 24.04 on Windows.
- Rules I set: commits under my name only (no AI attribution lines); every number in the docs comes
  from an actual run; small steps that pass tests; plain-English explanations plus interview Q&A for
  every stage in docs/notes.md.

## The CPU (rtl/core.sv and friends)
- RV32IM + Zicsr, Zicntr, Zifencei; single core, in-order, machine mode only.
- 5-stage pipeline IF-ID-EX-MEM-WB. Forwarding from MEM and WB; 1-cycle load-use stall. Loads and
  stores send their address from EX; data comes back in MEM and is registered into WB (a timing fix).
- Multiply 3 cycles, divide 34 cycles (iterative unit).
- Precise exceptions in EX (illegal, ECALL, EBREAK, misaligned); mtvec/mepc/mcause/mtval, MRET.
- Branch predictor (rtl/bpred.sv): 32-entry BTB, gshare with 256 2-bit counters (8 bits of global
  history), 4-entry return-address stack; speculative history/stack restored from a committed copy
  on every redirect. EX checks every prediction with a carry-free a+b==c target check.
- Caches (rtl/cache.sv): instruction and write-back data caches, 16-byte lines, direct-mapped or
  2-way, store forwarding, FENCE.I flush; an arbiter shares the SDRAM line port.
- Performance counters: cycles, instret, branches, mispredicts, load-use, mul/div wait, memory wait,
  I$/D$ accesses and misses.

## The SoC on the FPGA (rtl/soc.sv)
Wishbone bus; boot ROM with a UART bootloader (BOOT/LOAD/BAUD commands, CRC-32, 2 Mbaud uploads);
64 KB on-chip RAM; own SDRAM controller for the 64 MB chip (word port + 16-byte burst line port;
read data captured by a falling-edge I/O-cell register 50 ns after READ); UART with 64-byte RX FIFO;
timer; GPIO (LEDs, switches, keys, 7-segment); VGA 640x480 in two modes (320x240x4-bit or
320x200x8-bit with a 256-entry palette); 16x16 INT8 systolic-array NPU (from my edge-ml-accelerator
project). Two Quartus revisions: full SoC (with NPU, no caches) and CPU-only (caches + 8-bit VGA,
used for Doom).

## Measured results (all real runs)
- CoreMark (EEMBC, 2000 iterations, valid >10 s run, GCC -O2): 2.699 CoreMark/MHz from on-chip RAM,
  2.661 from SDRAM through 4 KB caches (134.9 / 133.0 CoreMark at 50 MHz). Mispredicts 12.8% of
  branches (60% with no predictor).
- MNIST (784-64-10 int8) on the board: software 847,536 cycles/image, NPU 21,172 cycles/image,
  40.03x faster, 199/200 correct, every logit bit-exact with NumPy.
- Doom (doomgeneric + picolibc, Freedoom Phase 1): 11.7 fps in -timedemo demo1; playable with the
  laptop keyboard over UART (tools/doom_keys.py).
- FPGA: full SoC 35,772 LEs, 168/182 M9K, 56.97 MHz Fmax; CPU-only Doom build ~14,000 LEs,
  149/182 M9K, meets 50 MHz (Fmax varies 51-57 MHz between builds).
- Tradeoff table (12 configurations, Quartus cost vs CoreMark): predictor costs 1,657 LEs (12%) for
  +16.5%; caches have a knee at 2-4 KB; 2-way only helps small caches.
- Sky130 layout (core + predictor + 256-byte caches, OpenLane 2): 1.82 mm2 die, 95,916 instances,
  Magic/KLayout DRC 0, LVS 0; 68.9 MHz typical corner, 36.0 MHz slow corner (100C, 1.6 V); 149 mW
  estimated. Gate-level simulation of the final netlist: all 50 riscv-tests match Spike (24,360
  instructions). Not sign-off clean: 153 antenna violations, slow corner misses 50 MHz.

## Verification
Every retired instruction compared with Spike (lockstep via rvfi signals): riscv-tests rv32ui 42/42
and rv32um 8/8, directed assembly tests (forwarding, load-use, mul/div, FENCE.I, traps, branch
prediction), random RV32IM programs, C programs; all again with random memory stalls, through tiny
caches (direct-mapped and 2-way), and with no/bimodal/gshare predictors. SoC tests (UART-decoded
output, VGA frames captured and checked pixel by pixel, SDRAM model, bootloader, CoreMark CRCs, MNIST
bit-exact). Planted bugs prove the tests fail when they should. 591 tests pass (make test).

## Bugs found on the way (good interview stories)
- SDRAM bursts failed only on the board: fitter report showed no I/O input register (fan-out 8);
  a diagnostic with an uncached SDRAM window showed reads one cycle late; fixed with a falling-edge
  I/O-cell capture at the measured sweet spot.
- Timing with caches (47 MHz): moved the memory request to EX so WB only forwards registered values
  (55 MHz).
- Quartus reused a stale synthesized netlist between sweep builds, so several configurations came
  out identical; caught by suspicion, fixed by clearing the database per build and checking the
  parameter in the synthesis report.
- OpenLane: Synlig crashed (switched to sv2v), lint and Yosys limits (packed arrays).

## Where things are
rtl/ (design), tb/ (testbenches), tests/ (pytest + cocotb), sw/ (bootloader, C programs, CoreMark
port, Doom port), tools/ (upload.py, doom_keys.py, build scripts, sweeps, asic_report.py),
fpga/de10lite/ (Quartus), asic/ (OpenLane flow), docs/ (README results, notes.md with explanations
and interview questions, board_bringup.md, asic.md, results/ board logs).

## Status and what's left
All stages done (0-6 + Doom). Optional: fix the chip's antenna violations (diode insertion) and the
slow-corner timing (worst paths: minstret CSR write, then the branch-mispredict flush); film a demo;
possible future stages: interrupts + a small OS (FreeRTOS), out-of-order execution.
