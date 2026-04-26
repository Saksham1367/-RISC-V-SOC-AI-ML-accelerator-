#!/usr/bin/env python3
"""Launch GTKWave on the wave dump for a given suite."""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# suite -> (build_dir, top_module)
SUITES = {
    "alu":             ("alu",             "alu"),
    "regfile":         ("regfile",         "regfile"),
    "imm_gen":         ("imm_gen",         "imm_gen"),
    "riscv_core":      ("riscv_core",      "soc_core_tb_top"),
    "pe":              ("pe",              "pe"),
    "sa_buffer":       ("sa_buffer",       "sa_buffer"),
    "axil":            ("axil",            "axi4_lite_slave"),
    "accel_top":       ("accelerator_top", "accelerator_top"),
    "soc":             ("soc",             "soc_top"),
}


def main(argv):
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        print("usage: python scripts/open_waves.py <suite>")
        print("suites:", " ".join(SUITES.keys()))
        return 1
    suite = argv[1]
    if suite not in SUITES:
        print(f"unknown suite: {suite}")
        return 2
    build_dir, top = SUITES[suite]
    fst = REPO / "sim" / build_dir / f"{top}.fst"
    if not fst.exists():
        print(f"no wave file at {fst}")
        print("run with WAVES=1 first:")
        print(f"  WAVES=1 python scripts/run_tests.py {suite}")
        return 3
    subprocess.run(["gtkwave", str(fst)])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
