# Phase 3 — AXI4-Lite + SoC Integration

## Files

| File | Role |
|------|------|
| `rtl/axi/axi4_lite_slave.sv` | Generic AXI4-Lite slave with parameterised CSR bank (writable_mask + csr_in/csr_q/csr_write hooks) |
| `rtl/accelerator/accelerator_top.sv` | Wraps `sa_buffer` behind the AXI4-Lite slave; maps A rows, B rows, CTRL, STATUS, and 16 INT32 C words to register offsets |
| `rtl/axi/mem_to_axil.sv` | Bridges the RV32I core's simple memory interface to AXI4-Lite (master); handles full handshake + `S_DONE` drain so the CPU sees stable rdata for one cycle |
| `rtl/soc_top.sv` | SoC integration: RV32I core + IMEM + DMEM + accelerator + address routing |

## RV32I core change

Added `dmem_stall` input to `riscv_core` so the SoC interconnect can hold the
pipeline while an MMIO transaction is in flight.

- When `mem_stall = (ex_ctrl.mem_re | ex_ctrl.mem_we) & dmem_stall`, the PC,
  IF/ID register, and ID/EX register all hold; writeback is suppressed.
- This is a clean superset of the existing load-use stall logic — Phase 1
  tests still pass unchanged.

## Memory map (accelerator slave, base `0x2000_0000`)

| Offset | Reg     | Access | Description |
|--------|---------|--------|-------------|
| `0x000` | CTRL        | RW | `[0]` start (W1 to start) |
| `0x004` | STATUS      | R  | `[0]` busy, `[1]` done |
| `0x008` | MATRIX_SIZE | RW | reserved (4×4 in v1) |
| `0x010-0x01C` | A_ROW0..3 | RW | Row i = 4 packed INT8 (LSB = col 0) |
| `0x020-0x02C` | B_ROW0..3 | RW | Row i = 4 packed INT8 |
| `0x030-0x06C` | C[i*4 + j] | R  | INT32 result, row-major |

## SoC address routing

| Range | Target |
|-------|--------|
| `0x0000_xxxx` | Instruction SRAM (fetch path only) |
| `0x1000_xxxx` | Data SRAM (single-cycle, no stall) |
| `0x2000_xxxx` | Accelerator AXI4-Lite slave (multi-cycle, stalls core) |

## End-to-end test

`verif/cocotb/soc/test_soc.py` assembles a small RV32I program (using
`common.rv_isa`) that:

1. Sets up base pointers (`x10 = 0x20000000`, `x11 = 0x10000000`).
2. Copies 4 packed A rows from data SRAM → accelerator.
3. Copies 4 packed B rows.
4. Writes `1` to CTRL (start).
5. Polls STATUS in a tight loop until `done` bit is set.
6. Reads back 16 C words and writes them to data SRAM at offset `0x100`.
7. Halts via `jal x0, 0`.

The cocotb harness pre-loads operands, runs ~8000 cycles, then reads the
result region from DSRAM and compares against a NumPy golden model.

## Results

```
AXI4-Lite slave             4/4   PASS  (write/read, wstrb, R/O, 60-iter random storm)
Accelerator top (AXI4-Lite) 3/3   PASS  (identity, 10 random INT8 matmuls, back-to-back)
SoC top (full integration)  2/2   PASS  (identity, 5 random INT8 matmuls via RV32I program)

Phase 3 total: 9/9 PASS
Cumulative   : 42/42 PASS across 9 suites
```

## Notable design moments

- **Bridge `S_DONE` drain state.** First version of `mem_to_axil` had a subtle
  bug: when bridge state was IDLE and `req_valid` rose, `req_stall` was 0
  for one cycle, so the CPU committed the load using the stale `rdata_q`
  from the previous transaction (the polling loop's STATUS=2 was being
  written into C[0][0]). The fix:
  - assert `req_stall` immediately on a new request (even in IDLE),
  - add an explicit `S_DONE` state where `req_stall=0` and `rdata_q` is held
    so the CPU's writeback samples the right value, then drop to IDLE next
    cycle.
- **Address-stable holding** in `fetch.sv` (Phase 1 fix): same family of
  issue — held register's data must not be overwritten by speculative
  re-reads while stalled.
