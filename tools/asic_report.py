"""Summarize the latest OpenLane 2 run (asic/runs/<tag>/final/metrics.json): area, cell count,
timing at the 50 MHz target, maximum frequency, power, and the DRC/LVS checks.

    python3 tools/asic_report.py [RUN_DIR]
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

WANTED = [  # (label, metric name in metrics.json)
    ("Core area (um^2)", "design__core__area"),
    ("Cell area (um^2)", "design__instance__area"),
    ("Standard cells", "design__instance__count"),
    ("Utilization", "design__instance__utilization"),
    ("Setup worst slack at 20 ns (ns)", "timing__setup__ws"),
    ("Hold worst slack (ns)", "timing__hold__ws"),
    ("Total power (W)", "power__total"),
    ("Magic DRC errors", "magic__drc_error__count"),
    ("KLayout DRC errors", "klayout__drc_error__count"),
    ("LVS errors", "design__lvs_error__count"),
    ("Antenna violations", "antenna__violating__nets"),
]


def main():
    if len(sys.argv) > 1:
        run = Path(sys.argv[1])
    else:
        runs = sorted((ROOT / "asic" / "runs").glob("*/final/metrics.json"),
                      key=lambda p: p.stat().st_mtime)
        if not runs:
            sys.exit("no run with final/metrics.json under asic/runs")
        run = runs[-1].parents[1]
    metrics = json.loads((run / "final" / "metrics.json").read_text())
    print(f"run: {run}")
    for label, key in WANTED:
        print(f"  {label:<34} {metrics.get(key, 'not reported')}")
    ws = metrics.get("timing__setup__ws")
    if isinstance(ws, (int, float)):
        print(f"  {'Fmax (from the 20 ns slack)':<34} {1000 / (20 - ws):.1f} MHz")
    others = sorted(k for k in metrics if "error" in k or "violat" in k)
    print("  other check counters:", {k: metrics[k] for k in others if k not in dict(WANTED).values()})


if __name__ == "__main__":
    main()
