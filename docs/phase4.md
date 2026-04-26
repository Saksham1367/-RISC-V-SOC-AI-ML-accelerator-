# Phase 4 — Verification Environment (cocotb-flavoured UVM)

This phase upgrades the directed cocotb tests of phases 1–3 with the verification
methodology that big-sim UVM provides — constrained-random stimulus, scoreboards,
functional coverage, and protocol assertions — using cocotb's open-source stack.

## What's new

| File | Purpose |
|------|---------|
| `verif/cocotb/common/scoreboard.py`     | Reusable `Scoreboard` class — counts pass/fail, dumps mismatches with context |
| `verif/cocotb/common/coverage.py`       | Wrapper around `cocotb_coverage` that auto-dumps per-suite reports under `sim/coverage/` |
| `verif/cocotb/common/axil_monitor.py`   | Live AXI4-Lite protocol monitor: stickiness, payload stability, response codes |
| `verif/assertions/axi4_lite_props.sv`   | Procedural-style RTL-side AXI4-Lite checker (SVA-equivalent, Icarus-friendly) |
| `verif/assertions/core_props.sv`        | Procedural micro-arch checker (x0 invariant, branch flush) |
| `verif/cocotb/core/riscv_core/test_riscv_core_random.py` | RV32I instruction-stream random tester with golden Python interpreter + coverage |
| `verif/cocotb/soc/test_soc_random.py`   | SoC-level constrained-random matmul tester with scoreboard + coverage |
| `scripts/coverage_report.py`            | Aggregates the per-suite JSON dumps into Markdown + HTML |

## Why cocotb instead of UVM?

UVM requires a commercial simulator (VCS / Questa / Xcelium). Cocotb gives the
same methodology in Python — Agent ↔ AxiLiteMaster, Monitor ↔ AxiLiteMonitor,
Sequence ↔ test coroutine, Scoreboard ↔ `Scoreboard` class, Functional coverage
↔ `cocotb_coverage.CoverPoint/CoverCross`. Resume bullet says *"cocotb-based
verification environment inspired by UVM methodology"* — accurate and honest.

## RV32I random ISA tester

`test_riscv_core_random.py` builds 60-instruction random programs from a
constrained safe-op set and runs them on the DUT. A Python golden interpreter
(`RVModel`) executes the same program and we scoreboard register-by-register
at the end.

* **8 random programs** × **31 register comparisons** = **248 checks** per run.
* All instructions hit a `CoverPoint` so we get a per-opcode coverage histogram.

## SoC random + coverage

`test_soc_random.py` reuses the assembled program from `test_soc.py` and drives
50 random matmuls through the full RV32I → AXI4-Lite → systolic-array path,
with constrained generators for sign mix, density, and value-range corners.

Coverage points (functional):
* `top.matmul.a_sign` / `b_sign` — all_pos / all_neg / mixed / all_zero
* `top.matmul.density` — sparse / medium / dense (non-zero count)
* `top.matmul.max_abs` — small / medium / large / max
* `top.matmul.cross.sign_density` — cross of A sign × density

## AXI4-Lite protocol checks

Two complementary implementations of the same property set:

1. **`verif/assertions/axi4_lite_props.sv`** — procedural RTL module with
   `always_ff` checks on every clock. Designed to be `bind`-able where a
   simulator supports it.

2. **`verif/cocotb/common/axil_monitor.py`** — live cocotb monitor that
   samples every clock. Used by the AXI4-Lite suite.

Properties enforced by both:
* VALID is sticky until READY (no glitching on AW/W/B/AR/R)
* AWADDR / WDATA / WSTRB / ARADDR stable while VALID is held without READY
* BRESP and RRESP always OKAY (`2'b00`)

## Coverage results (last run)

```
core_random
  core.instr.kind                                51.52%   (17 / 33 instruction kinds hit)

soc_random
  top.matmul.a_sign                             100.00%
  top.matmul.b_sign                             100.00%
  top.matmul.density                            100.00%
  top.matmul.max_abs                             75.00%
  top.matmul.cross.sign_density                  66.67%
  ----------------------------------------------------
  Suite total                                    81.48%
```

`scripts/coverage_report.py` produces `sim/coverage/index.html` for a clean
visual report.

## How to run

```bash
source /c/oss-cad-suite/environment
export PATH="/c/Users/$USER/AppData/Roaming/Python/Python313/Scripts:$PATH"

# Random + coverage suites (slow ~2 min total)
python scripts/run_tests.py core_random soc_random

# Aggregate coverage into Markdown + HTML
python scripts/coverage_report.py
```

## Cumulative regression

```
Suite                                   Tests
ALU                                       3/3   ✓
Regfile                                   5/5   ✓
Immediate generator                       6/6   ✓
RISC-V core integration                   8/8   ✓
PE                                        6/6   ✓
Systolic array buffer (matmul)            5/5   ✓
AXI4-Lite slave (with protocol monitor)   4/4   ✓
Accelerator top (matmul over AXI4-Lite)   3/3   ✓
SoC top (RV32I drives accelerator)        2/2   ✓
RV32I core random instruction stream      1/1   ✓  (248 register checks)
SoC random + coverage                     1/1   ✓  (50 random matmuls)
─────────────────────────────────────────────────
TOTAL                                    44/44   ALL PASS
```
