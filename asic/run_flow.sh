#!/usr/bin/env bash
# Stage 6: rtl/rv32im_asic.sv (core + 256-byte I$ and D$, flip-flop RAMs) to a Sky130 GDS with
# OpenLane 2. Run from the repository root, inside OpenLane 2's Nix shell:
#
#   nix-shell --pure ~/openlane2/shell.nix --run "bash asic/run_flow.sh"
#
# 1. sv2v turns the SystemVerilog into plain Verilog (Yosys reads only part of SystemVerilog),
#    with ASIC defined so the RAMs are flip-flops instead of the FPGA's block-RAM primitive.
# 2. OpenLane 2 runs synthesis, floorplan, placement, clock tree, routing, DRC, LVS and STA.
#    Results: asic/runs/<tag>/final/ (GDS, netlists, metrics.json); summary with
#    python3 tools/asic_report.py.
set -euo pipefail
cd "$(dirname "$0")/.."

RTL=(rtl/rv_pkg.sv rtl/alu.sv rtl/regfile.sv rtl/decoder.sv rtl/muldiv.sv rtl/csr.sv
     rtl/bpred.sv rtl/core.sv rtl/cache_ram.sv rtl/cache.sv rtl/mem_arbiter.sv rtl/rv32im_asic.sv)

mkdir -p asic/build
if command -v sv2v >/dev/null; then
    SV2V=(sv2v)
else
    SV2V=(nix run nixpkgs#sv2v --)          # not in OpenLane's shell: take it from nixpkgs
fi
"${SV2V[@]}" -DASIC --top=rv32im_asic "${RTL[@]}" > asic/build/rv32im_asic.v
echo "asic/build/rv32im_asic.v: $(wc -l < asic/build/rv32im_asic.v) lines"

openlane asic/config.json "$@"
