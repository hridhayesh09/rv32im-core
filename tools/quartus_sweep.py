"""Compile the CPU-only build (fpga/de10lite/rv32im_cpu.qsf) with several cache and branch
predictor configurations and collect logic elements, M9K blocks and Fmax: the cost side of the
tradeoff table (the CoreMark side is tools/coremark_sweep.py, with the same configuration names).

    python tools/quartus_sweep.py [FILTER]      (Windows, Quartus on the PATH or at QUARTUS_BIN)

Each build uses a temporary revision, rv32im_sweep, and takes about 10 minutes. Results are
appended to build/quartus_sweep.csv as each build finishes; configurations already in it are
skipped, so an interrupted sweep resumes. The project file is restored at the end (Quartus adds
the temporary revision to it).
"""

import csv
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FPGA = ROOT / "fpga" / "de10lite"
QUARTUS_BIN = Path(os.environ.get("QUARTUS_BIN", r"C:\altera_lite\25.1std\quartus\bin64"))

DEFAULT = dict(ICACHE_SIZE=4096, ICACHE_WAYS=1, DCACHE_SIZE=4096, DCACHE_WAYS=1,
               BP_MODE=2, BTB_BITS=5, BHT_BITS=8, RAS_DEPTH=4)

CONFIGS = {
    "nobp":       dict(BP_MODE=0),
    "bimodal":    dict(BP_MODE=1, RAS_DEPTH=0),
    "gshare":     dict(RAS_DEPTH=0),
    "gshare-ras": dict(),
    "btb16":      dict(BTB_BITS=4),
    "btb64":      dict(BTB_BITS=6),
    "bht1k":      dict(BHT_BITS=10),
    "1k-dm":      dict(ICACHE_SIZE=1024, DCACHE_SIZE=1024),
    "2k-dm":      dict(ICACHE_SIZE=2048, DCACHE_SIZE=2048),
    "8k-dm":      dict(ICACHE_SIZE=8192, DCACHE_SIZE=8192),
    "1k-2way":    dict(ICACHE_SIZE=1024, DCACHE_SIZE=1024, ICACHE_WAYS=2, DCACHE_WAYS=2),
    "4k-2way":    dict(ICACHE_WAYS=2, DCACHE_WAYS=2),
}


def report_value(path, pattern):
    m = re.search(pattern, path.read_text(errors="replace"), re.M)
    return m.group(1) if m else ""


def bpred_bht_bits(map_report):
    """BHT_BITS of the branch predictor instance, from the synthesis report's parameter tables."""
    section = ""
    for line in map_report.read_text(errors="replace").splitlines():
        if line.startswith("; Parameter Settings for User Entity Instance:"):
            section = line
        elif section.rstrip(" ;").endswith("bpred:u_bpred") and line.startswith("; BHT_BITS"):
            return int(line.split(";")[2])
    return None


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else ""
    base = (FPGA / "rv32im_cpu.qsf").read_text()
    base = re.sub(r"^set_parameter -name (ICACHE|DCACHE)_\w+ .*\n", "", base, flags=re.M)
    out = ROOT / "build" / "quartus_sweep.csv"
    out.parent.mkdir(parents=True, exist_ok=True)
    new_file = not out.exists()
    done = set() if new_file else {row[0] for row in csv.reader(out.open())}
    qpf = FPGA / "rv32im_soc.qpf"
    qpf_text = qpf.read_bytes()
    try:
        sweep(only, base, out, new_file, done)
    finally:
        qpf.write_bytes(qpf_text)
        (FPGA / "rv32im_sweep.qsf").unlink(missing_ok=True)


def sweep(only, base, out, new_file, done):
    with out.open("a", newline="") as f:
        writer = csv.writer(f)
        if new_file:
            writer.writerow(["config", "LEs", "M9K", "Fmax_MHz", "setup_slack_ns"])
        for name, changes in CONFIGS.items():
            if only not in name or name in done:
                continue
            params = {**DEFAULT, **changes}
            qsf = base + "".join(f"set_parameter -name {k} {v}\n" for k, v in params.items())
            (FPGA / "rv32im_sweep.qsf").write_text(qsf)
            # Start from an empty database: Quartus otherwise reuses the synthesized netlist of
            # a module from an earlier build even when its parameters changed (seen here: the
            # branch predictor kept BHT_BITS = 8 after it was set to 10).
            for d in ("db", "incremental_db"):
                shutil.rmtree(FPGA / d, ignore_errors=True)
            log = ROOT / "build" / f"quartus_sweep_{name}.log"
            with log.open("w") as lf:
                result = subprocess.run([str(QUARTUS_BIN / "quartus_sh"), "--flow", "compile",
                                         "rv32im_soc", "-c", "rv32im_sweep"],
                                        cwd=FPGA, stdout=lf, stderr=subprocess.STDOUT)
            if result.returncode != 0:
                print(f"{name}: compile failed, see {log}")
                continue
            reports = FPGA / "output_files"
            for ext in ("fit.rpt", "map.rpt", "sta.rpt"):   # kept per configuration
                shutil.copy(reports / f"rv32im_sweep.{ext}", ROOT / "build" / f"quartus_sweep_{name}.{ext}")
            les = report_value(reports / "rv32im_sweep.fit.summary",
                               r"Total logic elements : ([\d,]+)").replace(",", "")
            m9k = report_value(reports / "rv32im_sweep.fit.rpt", r"^; M9Ks\s+; (\d+) /")
            fmax = report_value(reports / "rv32im_sweep.sta.rpt",
                                r"^; ([\d.]+) MHz ; [\d.]+ MHz\s+; clk50")
            slack = report_value(reports / "rv32im_sweep.sta.summary",
                                 r"Setup 'clk50'\s*\nSlack : (-?[\d.]+)")
            # Check that the parameters really reached the predictor.
            used = bpred_bht_bits(ROOT / "build" / f"quartus_sweep_{name}.map.rpt")
            if used is not None and used != params["BHT_BITS"]:
                print(f"{name}: predictor built with BHT_BITS={used}, wanted {params['BHT_BITS']}")
                continue
            writer.writerow([name, les, m9k, fmax, slack])
            f.flush()
            print(f"{name}: {les} LEs, {m9k} M9K, {fmax} MHz, slack {slack} ns", flush=True)


if __name__ == "__main__":
    main()
