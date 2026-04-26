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
RTL_ACC = REPO / "rtl" / "accelerator"
COCOTB = REPO / "verif" / "cocotb"

# Make common helpers importable from any test module
sys.path.insert(0, str(COCOTB))


def _runner(name: str, sources: list[Path], top: str, test_module: str,
            test_dir: Path, build_dir: Path,
            parameters: dict | None = None) -> int:
    from cocotb_tools.runner import get_runner

    print(f"\n========== Suite: {name} ==========")
    runner = get_runner("icarus")
    runner.build(
        sources=[str(p) for p in sources],
        hdl_toplevel=top,
        build_args=["-g2012"],
        parameters=parameters or {},
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


def run_accelerator_top() -> int:
    return _runner(
        name="Accelerator top (matmul over AXI4-Lite)",
        sources=[
            REPO / "rtl" / "accelerator" / "sa_pkg.sv",
            REPO / "rtl" / "accelerator" / "pe.sv",
            REPO / "rtl" / "accelerator" / "sa_top.sv",
            REPO / "rtl" / "accelerator" / "sa_buffer.sv",
            REPO / "rtl" / "axi" / "axi4_lite_slave.sv",
            REPO / "rtl" / "accelerator" / "accelerator_top.sv",
        ],
        top="accelerator_top",
        test_module="test_accelerator_top",
        test_dir=COCOTB / "accelerator" / "accelerator_top",
        build_dir=REPO / "sim" / "accelerator_top",
    )


def run_soc_random() -> int:
    return _runner(
        name="SoC random+coverage (constrained-random matmul stream)",
        sources=[
            REPO / "rtl" / "core" / "riscv_pkg.sv",
            REPO / "rtl" / "core" / "alu.sv",
            REPO / "rtl" / "core" / "regfile.sv",
            REPO / "rtl" / "core" / "imm_gen.sv",
            REPO / "rtl" / "core" / "decoder.sv",
            REPO / "rtl" / "core" / "branch_unit.sv",
            REPO / "rtl" / "core" / "fetch.sv",
            REPO / "rtl" / "core" / "hazard_unit.sv",
            REPO / "rtl" / "core" / "execute.sv",
            REPO / "rtl" / "core" / "load_align.sv",
            REPO / "rtl" / "core" / "riscv_core.sv",
            REPO / "rtl" / "memory" / "sram.sv",
            REPO / "rtl" / "core" / "imem_sync.sv",
            REPO / "rtl" / "accelerator" / "sa_pkg.sv",
            REPO / "rtl" / "accelerator" / "pe.sv",
            REPO / "rtl" / "accelerator" / "sa_top.sv",
            REPO / "rtl" / "accelerator" / "sa_buffer.sv",
            REPO / "rtl" / "axi" / "axi4_lite_slave.sv",
            REPO / "rtl" / "accelerator" / "accelerator_top.sv",
            REPO / "rtl" / "axi" / "mem_to_axil.sv",
            REPO / "rtl" / "soc_top.sv",
        ],
        top="soc_top",
        test_module="test_soc_random",
        test_dir=COCOTB / "soc",
        build_dir=REPO / "sim" / "soc_random",
    )


def run_core_random() -> int:
    return _runner(
        name="RV32I core random instruction stream + coverage",
        sources=[
            REPO / "rtl" / "core" / "riscv_pkg.sv",
            REPO / "rtl" / "core" / "alu.sv",
            REPO / "rtl" / "core" / "regfile.sv",
            REPO / "rtl" / "core" / "imm_gen.sv",
            REPO / "rtl" / "core" / "decoder.sv",
            REPO / "rtl" / "core" / "branch_unit.sv",
            REPO / "rtl" / "core" / "fetch.sv",
            REPO / "rtl" / "core" / "hazard_unit.sv",
            REPO / "rtl" / "core" / "execute.sv",
            REPO / "rtl" / "core" / "load_align.sv",
            REPO / "rtl" / "core" / "riscv_core.sv",
            REPO / "rtl" / "memory" / "sram.sv",
            REPO / "rtl" / "core" / "imem_sync.sv",
            REPO / "rtl" / "core" / "soc_core_tb_top.sv",
        ],
        top="soc_core_tb_top",
        test_module="test_riscv_core_random",
        test_dir=COCOTB / "core" / "riscv_core",
        build_dir=REPO / "sim" / "core_random",
    )


def run_soc() -> int:
    return _runner(
        name="SoC top — RV32I program drives accelerator end-to-end",
        sources=[
            REPO / "rtl" / "core" / "riscv_pkg.sv",
            REPO / "rtl" / "core" / "alu.sv",
            REPO / "rtl" / "core" / "regfile.sv",
            REPO / "rtl" / "core" / "imm_gen.sv",
            REPO / "rtl" / "core" / "decoder.sv",
            REPO / "rtl" / "core" / "branch_unit.sv",
            REPO / "rtl" / "core" / "fetch.sv",
            REPO / "rtl" / "core" / "hazard_unit.sv",
            REPO / "rtl" / "core" / "execute.sv",
            REPO / "rtl" / "core" / "load_align.sv",
            REPO / "rtl" / "core" / "riscv_core.sv",
            REPO / "rtl" / "memory" / "sram.sv",
            REPO / "rtl" / "core" / "imem_sync.sv",
            REPO / "rtl" / "accelerator" / "sa_pkg.sv",
            REPO / "rtl" / "accelerator" / "pe.sv",
            REPO / "rtl" / "accelerator" / "sa_top.sv",
            REPO / "rtl" / "accelerator" / "sa_buffer.sv",
            REPO / "rtl" / "axi" / "axi4_lite_slave.sv",
            REPO / "rtl" / "accelerator" / "accelerator_top.sv",
            REPO / "rtl" / "axi" / "mem_to_axil.sv",
            REPO / "rtl" / "soc_top.sv",
        ],
        top="soc_top",
        test_module="test_soc",
        test_dir=COCOTB / "soc",
        build_dir=REPO / "sim" / "soc",
    )


def run_axil() -> int:
    return _runner(
        name="AXI4-Lite slave (with cocotb protocol monitor)",
        sources=[REPO / "rtl" / "axi" / "axi4_lite_slave.sv"],
        top="axi4_lite_slave",
        test_module="test_axil",
        test_dir=COCOTB / "accelerator" / "axi_lite",
        build_dir=REPO / "sim" / "axil",
        parameters={"NUM_REGS": 8},
    )


def run_pe() -> int:
    return _runner(
        name="PE",
        sources=[RTL_ACC / "sa_pkg.sv", RTL_ACC / "pe.sv"],
        top="pe",
        test_module="test_pe",
        test_dir=COCOTB / "accelerator" / "pe",
        build_dir=REPO / "sim" / "pe",
    )


def run_sa_buffer() -> int:
    return _runner(
        name="Systolic array buffer (matrix multiply)",
        sources=[
            RTL_ACC / "sa_pkg.sv",
            RTL_ACC / "pe.sv",
            RTL_ACC / "sa_top.sv",
            RTL_ACC / "sa_buffer.sv",
        ],
        top="sa_buffer",
        test_module="test_sa_buffer",
        test_dir=COCOTB / "accelerator" / "sa_buffer",
        build_dir=REPO / "sim" / "sa_buffer",
    )


SUITES = {
    "alu":        run_alu,
    "regfile":    run_regfile,
    "imm_gen":    run_imm_gen,
    "riscv_core": run_riscv_core,
    "pe":         run_pe,
    "sa_buffer":  run_sa_buffer,
    "axil":       run_axil,
    "accel_top":  run_accelerator_top,
    "soc":        run_soc,
    "soc_random": run_soc_random,
    "core_random": run_core_random,
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
