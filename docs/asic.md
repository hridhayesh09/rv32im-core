# Stage 6: the core as a Sky130 chip layout (OpenLane 2)

What gets built: `rtl/rv32im_asic.sv`, the core with 256-byte instruction and data caches (their
RAMs are flip-flops when `ASIC` is defined), the branch predictor, and one 16-byte line port to
outside memory. It's the same module that every cached lockstep test runs (`tb/tb_cached.sv`), so
the RTL going into the flow is already checked instruction by instruction against Spike.

## Result (OpenLane 2.3.10, Sky130A, `sky130_fd_sc_hd`, 20 ns clock target)

![Layout of rv32im_asic: signal routing layers li1 and metal 1-3](images/asic_layout.png)

*Signal routing (local interconnect and metal 1 to 3); the power grid on metal 4 and 5 is hidden.
`tools/layout_png.py` renders it from the final GDS.*

| | First run (2026-11-11) | **Current (2026-11-12)** |
|---|---|---|
| Die / core area | 1.82 / 1.77 mm² | **1.83 / 1.79 mm²** |
| Cell area, utilization | 0.81 mm², 45% | 0.94 mm², 52% |
| Instances | 95,916 | 146,809 (inserted diodes and buffers) |
| DRC (Magic, KLayout) / LVS | 0 / 0 / 0 | **0 / 0 / 0** |
| Antenna violations | 153 nets | **29 nets** (40 pins) |
| Typical corner (25 °C, 1.8 V) | +5.49 ns: 68.9 MHz | **+7.16 ns: 77.9 MHz** |
| Fast corner (-40 °C, 1.95 V) | +10.54 ns: 105.7 MHz | +10.47 ns: 104.9 MHz |
| Slow corner (100 °C, 1.6 V) | -7.81 ns: 36.0 MHz | **-3.97 ns: 41.7 MHz** (worst extraction -5.08 ns: 39.9 MHz) |
| Hold | met (worst +0.11 ns) | met (worst +0.07 ns) |
| Power (OpenSTA, default switching activity) | 149 mW | 135 mW |
| Max slew / cap / fanout warnings, typical corner | 101 / 72 / 653 | 945 / 189 / 5,263 |
| Gate-level simulation (50 riscv-tests vs Spike) | 50 / 50 (24,360 instructions) | **50 / 50** (24,360 instructions) |

Raw metrics: [results/asic_metrics_2026-11-11.json](results/asic_metrics_2026-11-11.json) and
[results/asic_metrics_2026-11-12.json](results/asic_metrics_2026-11-12.json); `tools/asic_report.py`
prints them.

What changed between the runs:
- **RTL** (found from the first run's timing report): the slowest path, by 3.7 ns, was a software
  write to the `minstret` counter (forwarding, CSR logic and a 64-bit subtraction in one cycle). The
  write now takes two cycles and flushes the younger instructions like FENCE.I. The next path, the
  branch-mispredict flush, gated the load of every field of two pipeline registers; now it only
  clears their valid bits. Same cycle counts on the board.
- **Flow settings**: diode insertion on (heuristic, and on input ports), and timing repair after
  global routing.

What it means:
- **DRC and LVS are clean** in both runs: the layout follows the fab's rules and matches the netlist.
  Antenna violations dropped from 153 to 29 nets; the rest need more repair iterations or manual
  fixes before a real tape-out.
- **The slow corner still misses 50 MHz** (41.7 MHz). After the fixes the worst paths are spread over
  many unrelated places (performance counters, BTB writes, cache data, return stack): the eleven
  worst register groups are all between -2.8 and -4.0 ns, so no single path is left to fix: 50 MHz
  there would need a deeper pipeline.
- **The electrical warnings grew**: the inserted diodes and buffers add load, so more nets exceed the
  max slew, capacitance and fanout limits. These are the next thing to repair.

## How it was brought up (and three tool problems)

1. OpenLane's linter (an older Verilator) rejected the branch predictor's reset loop (non-blocking
   writes to an array inside a `for` loop). The counters and BTB valid bits became packed vectors,
   reset in one assignment.
2. OpenLane's SystemVerilog plugin (Synlig) crashed with an internal Yosys assertion. The flow now
   converts the design to plain Verilog with sv2v first (from nixpkgs).
3. Yosys couldn't read a two-dimensional unpacked array (`data_out[way][lane]` in the cache) in the
   converted code. The cache's arrays became packed arrays (indexed the same way).

After each change: the cached lockstep tests, the predictor tests, a Quartus build, and on the
board the SDRAM diagnostic and CoreMark from SDRAM (751,703,684 cycles, identical to before).

## Installing the tools (done once, in WSL Ubuntu)

1. **Nix.** Follow the "Nix-based installation" page of the OpenLane 2 documentation
   (openlane2.readthedocs.io). It installs Nix (asks for your password once) and adds OpenLane's
   binary cache, so the tools download ready-made instead of being compiled for hours. Close and
   reopen the terminal afterwards.
2. **OpenLane 2:**
   ```bash
   git clone https://github.com/efabless/openlane2 ~/openlane2
   ```
3. **Icarus Verilog** (for the gate-level simulation):
   ```bash
   sudo apt install iverilog
   ```

## Running it

From the repository root in WSL:
```bash
nix-shell ~/openlane2/shell.nix --run "bash asic/run_flow.sh"
python3 tools/asic_report.py
python -m pytest tests/core/test_gate_level.py
```
The first `nix-shell` downloads the tools and the Sky130 PDK (several GB). The flow itself
(synthesis, floorplan, placement, clock tree, routing, DRC, LVS, timing) takes a while for a design
this size. Results go to `asic/runs/<date>/final/`: the GDS layout, the netlists, and
`metrics.json`. A screenshot of the layout: open `final/gds/rv32im_asic.gds` in KLayout (part of the
same Nix shell: `klayout asic/runs/<date>/final/gds/rv32im_asic.gds`).

## What to expect and what to check

- **DRC and LVS clean**: `tools/asic_report.py` prints the error counts (Magic and KLayout DRC, LVS);
  all must be 0.
- **Timing**: the setup slack at the 20 ns target at each corner; Fmax follows from it.
- **Gate-level**: all 50 riscv-tests (rv32ui + rv32um) must match Spike on the final netlist.
