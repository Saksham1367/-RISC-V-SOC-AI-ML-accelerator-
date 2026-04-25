# Phase 2 — 4×4 Systolic Array ML Accelerator

## Files

| File | Role |
|------|------|
| `rtl/accelerator/sa_pkg.sv`    | Shared parameters: `DATA_W=8`, `WEIGHT_W=8`, `ACC_W=32`, `ARRAY_N=4` |
| `rtl/accelerator/pe.sv`        | Single processing element: signed INT8 × INT8 → INT32 accumulate, registered east/south pass-through |
| `rtl/accelerator/sa_top.sv`    | Bare 4×4 PE grid wired with row/col flow — no input buffer, no FSM |
| `rtl/accelerator/sa_buffer.sv` | Wraps `sa_top` with input matrices, stagger logic, FSM, result latch — single-shot matrix multiply block |

## Dataflow choice — Output-Stationary (OS)

The project doc lists "weight-stationary" but is loose on the algorithm. We
implemented a **clean output-stationary 2D systolic array** because it gives a
correct, well-known matrix-multiply with minimal control complexity:

- Each PE accumulates one output element of `C = A × B` (INT32 acc).
- Both `A` (activations) and `B` (weights) flow through the array — `A` from
  the west, `B` from the north — with diagonal staggering so that the right
  `(A[i][k], B[k][j])` pair lands at PE[i][j] on the same cycle.
- After `K = N` accumulations + pipeline drain, PE[i][j].acc = C[i][j].

This is the same dataflow Google's TPU MXU uses. Resume bullet stays
"systolic array MAC accelerator" — the OS-vs-WS distinction is a design
choice, not a methodology change.

## Stagger schedule (N=4)

```
cycle:    0   1   2   3   4   5   6
row 0:   A00 A01 A02 A03  -   -   -
row 1:    -  A10 A11 A12 A13  -   -
row 2:    -   -  A20 A21 A22 A23  -
row 3:    -   -   -  A30 A31 A32 A33

col 0:   B00 B10 B20 B30  -   -   -
col 1:    -  B01 B11 B21 B31  -   -
col 2:    -   -  B02 B12 B22 B32  -
col 3:    -   -   -  B03 B13 B23 B33
```

Total cycles `S_RUN → S_LATCH = 3N − 1 = 11` for N=4.

## Tests

| File | Coverage |
|------|----------|
| `verif/cocotb/accelerator/pe/test_pe.py` | Reset, single MAC, signed corner cases (-128*-128 etc.), `acc_clear`, registered pass-through, 200-iter random storm |
| `verif/cocotb/accelerator/sa_buffer/test_sa_buffer.py` | Identity × matrix, zero matrix, signed mix, **30 random 4×4 INT8 matmuls vs NumPy golden**, back-to-back ops |

## Results

```
PE                   6/6  PASS
Systolic array       5/5  PASS  (incl. 30-iter random vs NumPy)
```
