# Architecture Reference

This document is the working spec for the SoC. It expands the project PDF with the concrete decisions we make during implementation.

## 1. RISC-V RV32I Core (Phase 1)

### Pipeline

3-stage in-order pipeline:

```
   ┌────────┐   ┌────────┐   ┌─────────┐
   │ Fetch  │──►│ Decode │──►│ Execute │
   └────────┘   └────────┘   └─────────┘
       ▲             │            │
       │             ▼            ▼
       │       ┌──────────┐  ┌─────────┐
       │       │ Regfile  │  │   ALU   │
       │       └──────────┘  └─────────┘
       │                          │
       └──── branch / jump ◄──────┘
```

### Hazard Strategy

- **Data hazards:** forward EX→ID; if a load is followed immediately by a dependent op, stall 1 cycle.
- **Control hazards:** flush IF/ID on taken branch or jump (1-cycle bubble).
- **Structural hazards:** none in 3-stage with split I/D memory.

### Instruction Set

Full RV32I base:

| Format | Instructions |
|--------|-------------|
| R-type | `add`, `sub`, `and`, `or`, `xor`, `sll`, `srl`, `sra`, `slt`, `sltu` |
| I-type | `addi`, `andi`, `ori`, `xori`, `slli`, `srli`, `srai`, `slti`, `sltiu`, `jalr` |
| Load   | `lb`, `lh`, `lw`, `lbu`, `lhu` |
| Store  | `sb`, `sh`, `sw` |
| Branch | `beq`, `bne`, `blt`, `bge`, `bltu`, `bgeu` |
| Jump   | `jal`, `jalr` |
| Upper  | `lui`, `auipc` |
| System | `ecall`, `ebreak` (stub for now) |
| Fence  | `fence` (NOP for single-core) |

## 2. Systolic Array Accelerator (Phase 2)

- 4×4 grid of Processing Elements (16 MACs)
- INT8 inputs / weights, INT32 accumulator
- **Weight Stationary** dataflow — weights loaded first, activations stream in
- Done after `2N − 1` cycles of streaming for an `N×N` multiply (here N=4)

### PE Datapath

```
        weight_in (8b, loaded once)
                │
                ▼
data_in ─►[ × ]──► * partial product (16b)
   (8b)         │
                ▼
              [ + ]──► accumulator (32b)
                │
                ▼
             acc_out
```

`data_in` propagates eastward; partial sums propagate southward. The done signal asserts when all 16 PEs have completed `N` accumulations.

## 3. AXI4 Bus Fabric (Phase 3)

### Two Channels

| Channel | Master | Slave | Purpose |
|---------|--------|-------|---------|
| AXI4-Lite | RISC-V Core | Accelerator CSRs | Control plane: start, mode, status |
| AXI4 Full | Accelerator DMA / RISC-V LSU | SRAM | Data plane: matrix transfers |

### CSR Map (AXI4-Lite, base `0x2000_0000`)

| Offset | Register | Bits | Description |
|--------|----------|------|-------------|
| `0x00` | CTRL | `[0]` start, `[1]` mode (0=load weights, 1=compute) | Kicks off operation |
| `0x04` | STATUS | `[0]` busy, `[1]` done, `[2]` error | Read-only status |
| `0x08` | SRC_ADDR | 32b | Source matrix address |
| `0x0C` | DST_ADDR | 32b | Destination address |
| `0x10` | MATRIX_SIZE | `[7:4]` rows, `[3:0]` cols | Max 4×4 in v1 |

## 4. Verification Strategy (Phase 4)

cocotb-based testbench per block, plus an integration TB at the SoC level. Reference (golden) models in NumPy. Functional coverage via `cocotb-coverage`. SVA properties checked alongside cocotb stimulus where the simulator supports them.
