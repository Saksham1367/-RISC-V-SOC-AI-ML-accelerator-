#!/usr/bin/env python3
"""
Phase 1 cocotb regression runner.

Uses cocotb 2.x's Python runner API directly — no Make required.
Run from any shell after activating OSS CAD Suite:

    source /c/oss-cad-suite/environment
    python scripts/run_tests.py [suite ...]

Available suites: alu | regfile | imm_gen | riscv_core | all
Default: all
"""
from __future__ import annotations

import sys
import argparse
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RTL_CORE = REPO / "rtl" / "core"
RTL_MEM = REPO / "rtl" / "memory"
COCOTB = REPO / "verif" / "cocotb"

# Make common helpers importable from any test module
sys.path.insert(0, str(COCOTB))


def _runner(name: str, sources: list[Path], top: str, test_module: str,
            test_dir: Path, build_dir: Path) -> int:
    from cocotb_tools.runner import get_runner

    print(f"\n========== Suite: {name} ==========")
    runner = get_runner("icarus")
    runner.build(
        sources=[str(p) for p in sources],
        hdl_toplevel=top,
        build_args=["-g2012"],
        timescale=("1ns", "1ps"),
        waves=False,
        always=True,
        build_dir=str(build_dir),
    )
    results = runner.test(
        hdl_toplevel=top,
        test_module=test_module,
        build_dir=str(build_dir),
        test_dir=str(test_dir),
        timescale=("1ns", "1ps"),
    )
    # results is a Path to the cocotb results.xml; non-zero failure raises CalledProcessError
    return 0


# ---------------------------------------------------------------------------
# Suite definitions
# ---------------------------------------------------------------------------
def run_alu() -> int:
    return _runner(
        name="ALU",
        sources=[RTL_CORE / "riscv_pkg.sv", RTL_CORE / "alu.sv"],
        top="alu",
        test_module="test_alu",
        test_dir=COCOTB / "core" / "alu",
        build_dir=REPO / "sim" / "alu",
    )


def run_regfile() -> int:
    return _runner(
        name="Regfile",
        sources=[RTL_CORE / "riscv_pkg.sv", RTL_CORE / "regfile.sv"],
        top="regfile",
        test_module="test_regfile",
        test_dir=COCOTB / "core" / "regfile",
        build_dir=REPO / "sim" / "regfile",
    )


def run_imm_gen() -> int:
    return _runner(
        name="Immediate generator",
        sources=[RTL_CORE / "riscv_pkg.sv", RTL_CORE / "imm_gen.sv"],
        top="imm_gen",
        test_module="test_imm_gen",
        test_dir=COCOTB / "core" / "imm_gen",
        build_dir=REPO / "sim" / "imm_gen",
    )


def run_riscv_core() -> int:
    sources = [
        RTL_CORE / "riscv_pkg.sv",
        RTL_CORE / "alu.sv",
        RTL_CORE / "regfile.sv",
        RTL_CORE / "imm_gen.sv",
        RTL_CORE / "decoder.sv",
        RTL_CORE / "branch_unit.sv",
        RTL_CORE / "fetch.sv",
        RTL_CORE / "hazard_unit.sv",
        RTL_CORE / "execute.sv",
        RTL_CORE / "load_align.sv",
        RTL_CORE / "riscv_core.sv",
        RTL_MEM / "sram.sv",
        RTL_CORE / "imem_sync.sv",
        RTL_CORE / "soc_core_tb_top.sv",
    ]
    return _runner(
        name="RISC-V core integration",
        sources=sources,
        top="soc_core_tb_top",
        test_module="test_riscv_core",
        test_dir=COCOTB / "core" / "riscv_core",
        build_dir=REPO / "sim" / "riscv_core",
    )


SUITES = {
    "alu":        run_alu,
    "regfile":    run_regfile,
    "imm_gen":    run_imm_gen,
    "riscv_core": run_riscv_core,
}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("suites", nargs="*", default=["all"],
                        help="Suite name(s) or 'all'.")
    args = parser.parse_args(argv)

    selected = list(SUITES.keys()) if "all" in args.suites else args.suites
    failures: list[str] = []

    for name in selected:
        fn = SUITES.get(name)
        if fn is None:
            print(f"unknown suite: {name}")
            return 2
        try:
            fn()
        except Exception as exc:
            print(f"!!! Suite {name} raised: {exc}")
            failures.append(name)

    print("\n" + "=" * 60)
    if failures:
        print(f"FAILED suites: {', '.join(failures)}")
        return 1
    print("ALL SUITES PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
