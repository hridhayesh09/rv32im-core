# Stage 6: the core as a Sky130 chip layout (OpenLane 2)

What gets built: `rtl/rv32im_asic.sv`, the core with 256-byte instruction and data caches (their
RAMs are flip-flops when `ASIC` is defined), the branch predictor, and one 16-byte line port to
outside memory. It's the same module that every cached lockstep test runs (`tb/tb_cached.sv`), so
the RTL going into the flow is already checked instruction by instruction against Spike.

## Status

Ready to run, not run yet: the tools need Nix (or Docker), which needs an administrator password.
Everything else is in place:

| Piece | File | Checked |
|---|---|---|
| ASIC top level | `rtl/rv32im_asic.sv` | all cached lockstep tests run on it; Verilator lint with `ASIC` defined |
| Technology-independent RAM | `rtl/cache_ram.sv` | `ASIC`: flip-flops; FPGA: block RAM; same behaviour |
| Flow script | `asic/run_flow.sh` | sv2v (SystemVerilog to Verilog), then OpenLane 2 |
| OpenLane configuration | `asic/config.json` | Sky130A, `sky130_fd_sc_hd` cells, 20 ns clock (50 MHz) |
| Results summary | `tools/asic_report.py` | area, slack, Fmax, power, DRC/LVS from `metrics.json` |
| Gate-level simulation | `tests/core/test_gate_level.py`, `tb/tb_asic_gl.sv` | riscv-tests on the final netlist in lockstep with Spike; skipped until a netlist exists |

## What you need to install (once, in WSL Ubuntu)

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

That's all; tell Claude when it's done and it runs the rest.

## Running it

From the repository root in WSL:
```bash
nix-shell --pure ~/openlane2/shell.nix --run "bash asic/run_flow.sh"
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
- **Timing**: the setup slack at the 20 ns target; Fmax is reported from it. No number is written
  down here until a run produces one.
- **Gate-level**: all 50 riscv-tests (rv32ui + rv32um) must match Spike on the final netlist.
