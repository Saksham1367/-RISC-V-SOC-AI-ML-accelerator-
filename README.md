# RISC-V SoC with Systolic Array ML Accelerator

> Industry-grade FPGA / RTL portfolio project — RV32I 3-stage pipelined CPU tightly coupled with a 4×4 systolic array INT8 matrix-multiply accelerator over an AXI4 fabric.

## Status

Project under active development. Phase progress tracked below.

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | RISC-V RV32I 3-stage core | In progress |
| 2 | 4×4 Systolic Array Accelerator | Pending |
| 3 | AXI4 / AXI4-Lite Bus Integration | Pending |
| 4 | cocotb Verification Environment | Pending |
| 5 | Regression + Yosys Synthesis + Docs | Pending |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                       SoC                               │
│                                                         │
│   ┌──────────────┐   AXI4-Lite   ┌──────────────────┐   │
│   │   RISC-V     │◄─────────────►│  Systolic Array  │   │
│   │  RV32I Core  │               │   4×4 PE Grid    │   │
│   │  (3-stage)   │   AXI4 Data   │ (Matrix Multiply)│   │
│   └──────┬───────┘◄═════════════►└────────┬─────────┘   │
│          │                                │             │
│          └────────────┬───────────────────┘             │
│                       │  Shared Memory Bus              │
│                ┌──────▼──────┐                          │
│                │     SRAM    │                          │
│                │ (Inst+Data) │                          │
│                └─────────────┘                          │
└─────────────────────────────────────────────────────────┘
```

## Memory Map

| Region | Base Address | Description |
|--------|--------------|-------------|
| Instruction SRAM | `0x0000_0000` | RISC-V code |
| Data SRAM        | `0x1000_0000` | RISC-V data + accelerator buffers |
| Accelerator CSRs | `0x2000_0000` | AXI4-Lite control registers |

## Tech Stack

| Category | Tool |
|----------|------|
| HDL | SystemVerilog |
| Simulator | Icarus Verilog |
| Linting | Verilator |
| Verification | **cocotb** (Python) — methodology inspired by UVM |
| Assertions | SystemVerilog Assertions (SVA) |
| Synthesis | Yosys (sky130 PDK) |
| Waveforms | GTKWave |
| Automation | Python 3 + Makefile |
| Toolchain | OSS CAD Suite |

> **Note on UVM:** The project doc specifies UVM, but UVM requires commercial simulators (VCS/Questa/Xcelium). On free tools we use cocotb, which delivers the same methodology (constrained random, scoreboards, golden models, functional coverage) in Python.

## Repository Layout

```
riscv-soc-ai-ml-accelerator/
├── rtl/
│   ├── core/           # RV32I CPU modules
│   ├── accelerator/    # Systolic array
│   ├── axi/            # AXI4 / AXI4-Lite interfaces
│   ├── memory/         # SRAM model
│   └── soc_top.sv      # Full SoC integration (Phase 3)
├── verif/
│   ├── cocotb/         # Python testbenches
│   ├── assertions/     # SVA properties
│   └── tests/          # Directed test vectors
├── scripts/            # Regression runner, golden model, coverage
├── synth/              # Yosys scripts and reports
├── sim/                # Simulation outputs (gitignored)
└── docs/               # Architecture docs and waveform screenshots
```

## How to Run

> Tooling setup is the first prerequisite — see [`docs/setup.md`](docs/setup.md).

```bash
# Activate the OSS CAD Suite environment (every shell session)
source /c/oss-cad-suite/environment

# Run a single test (example, after Phase 1 lands)
cd verif/cocotb/core/alu && make

# Run the full regression suite (Phase 5)
python scripts/regression.py
```

## Author

Saksham Dhingra — final-year ECE student.
