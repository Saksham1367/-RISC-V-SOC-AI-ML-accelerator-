# Phase 1 — RISC-V RV32I Core (Implementation Notes)

## Files

| File | Role |
|------|------|
| `rtl/core/riscv_pkg.sv`   | Shared types: opcodes, ALU op enum, control bundle |
| `rtl/core/alu.sv`         | RV32I ALU |
| `rtl/core/regfile.sv`     | 32×32 register file, async-read with same-cycle bypass |
| `rtl/core/imm_gen.sv`     | Immediate decoder (I/S/B/U/J) |
| `rtl/core/decoder.sv`     | Instruction → control bundle |
| `rtl/core/branch_unit.sv` | Branch condition evaluator |
| `rtl/core/fetch.sv`       | PC, IMEM addr, redirect |
| `rtl/core/hazard_unit.sv` | Forwarding + load-use stall logic |
| `rtl/core/execute.sv`     | ALU + branch + DMEM request gen |
| `rtl/core/load_align.sv`  | Sign/zero extension for LB/LBU/LH/LHU |
| `rtl/core/riscv_core.sv`  | 3-stage pipeline top |
| `rtl/core/imem_sync.sv`   | Synchronous-read IMEM wrapper around generic SRAM |
| `rtl/memory/sram.sv`      | Generic byte-strobed SRAM (used for IMEM and DMEM) |
| `rtl/core/soc_core_tb_top.sv` | TB harness with imem+dmem hookup |

## Pipeline

```
                      ┌────────────┐
                      │   IF       │  PC -> imem (1 cycle latency)
                      └─────┬──────┘
                            ▼
                     [ IF/ID  ]
                            │
                      ┌─────▼──────┐
                      │   ID       │  decode + regfile read
                      └─────┬──────┘
                            ▼
                     [ ID/EX  ]
                            │
                      ┌─────▼──────┐
                      │   EX       │  alu + branch + dmem + writeback
                      └────────────┘
```

- Branch resolution in EX → 2-cycle bubble on a taken branch.
- Forwarding path: EX result → ID rs1/rs2 mux.
- Load-use hazard: stall IF/ID 1 cycle, bubble EX.
- x0 hardwired to zero in regfile.
- Regfile internal write-before-read bypass (same-cycle write+read returns new value).

## Tests (Phase 1)

```
verif/cocotb/core/
├── alu/         test_alu.py        directed + 500-iter random across all ops
├── regfile/     test_regfile.py    x0, write/read, bypass, two-port, random storm
├── imm_gen/     test_imm_gen.py    every instruction format, sign extension, random
└── riscv_core/  test_riscv_core.py end-to-end: arithmetic, forwarding, branch
                                    (taken/not-taken), JAL link, load/store, load-use
                                    stall, x0 stays zero
```

Each subdir has its own Makefile and is invoked via cocotb's standard flow.

## How to run (after toolchain setup)

```bash
source /c/oss-cad-suite/environment
export PATH="/c/Users/$USER/AppData/Roaming/Python/Python313/Scripts:$PATH"

# All Phase 1 suites
python scripts/run_tests.py all

# A single suite
python scripts/run_tests.py alu
python scripts/run_tests.py riscv_core
```

Build artifacts (waveforms, .vvp) land under `sim/<suite>/` and can be opened
with `gtkwave sim/<suite>/dump.fst`.

## Phase 1 results — current

```
ALU                 3/3   PASS  (directed + 500-iter random + shift-mask)
Regfile             5/5   PASS  (x0, write/read, bypass, two-port, 500-iter storm)
Immediate generator 6/6   PASS  (I/S/B/U/J + 200-iter random)
RISC-V core         8/8   PASS  (arith, forwarding, branches taken/not, JAL,
                                 load/store, load-use stall, x0 stays zero)
Total: 22/22 PASS
```
