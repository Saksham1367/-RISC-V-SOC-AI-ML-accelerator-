"""
Phase 3 SoC integration test.

We assemble a small RV32I program in Python (using common.rv_isa) that:
  1. Initialises x10 = 0x20000000 (accelerator base) and x11 = 0x10000000
     (data SRAM base), but only the low 28 bits of dmem_addr matter; the
     high nibble is the routing select.
  2. For each of the 4 A rows: load a packed word from data SRAM and store
     it to A_ROW[i] in the accelerator.
  3. Same for B.
  4. Write 1 to CTRL to start.
  5. Poll STATUS until [1] (done) is set.
  6. Read C[0..15] from accelerator, write each word to data SRAM (0x100..).
  7. Spin (jal x0, 0) — testbench halts the simulation by reading C from
     SRAM and comparing.

Pre-loaded data layout in data SRAM:
  word index 0..3 : packed A rows
  word index 4..7 : packed B rows
  word index 64 onwards (0x100 byte offset / 0x40 word index): C results
"""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from common import rv_isa as isa

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

N = 4

# Accelerator memory map (we use low 28 bits only — soc_top routes by upper nibble)
ACC_BASE       = 0x20000000
OFF_CTRL       = 0x000
OFF_STATUS     = 0x004
OFF_A_BASE     = 0x010
OFF_B_BASE     = 0x020
OFF_C_BASE     = 0x030

# Data SRAM layout
DSRAM_BASE     = 0x10000000
A_PACKED_OFF   = 0x000   # 4 words at 0x10000000
B_PACKED_OFF   = 0x010   # 4 words at 0x10000010
C_RESULT_OFF   = 0x100   # 16 words at 0x10000100


def s32(x: int) -> int:
    x &= 0xFFFFFFFF
    return x - 0x100000000 if x & 0x80000000 else x


def pack_row(row):
    return ((row[3] & 0xFF) << 24) | ((row[2] & 0xFF) << 16) | \
           ((row[1] & 0xFF) << 8)  |  (row[0] & 0xFF)


def golden(A, B):
    if HAS_NUMPY:
        return (np.array(A, dtype=np.int64) @ np.array(B, dtype=np.int64)).tolist()
    C = [[0]*N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            C[i][j] = sum(A[i][k]*B[k][j] for k in range(N))
    return C


def assemble_program() -> list[int]:
    """Build a small program (list of 32-bit words) that copies operands to the
    accelerator, runs the multiply, polls done, and writes results back to
    data SRAM."""
    P = []

    # x10 = ACC_BASE  (lui upper, no addi needed because OFF_CTRL/etc add up)
    P.append(isa.lui  (10, ACC_BASE))             # x10 = 0x20000000
    P.append(isa.lui  (11, DSRAM_BASE))           # x11 = 0x10000000

    # Copy A rows: for i in 0..3:
    #   x12 = lw [x11 + (A_PACKED_OFF + 4i)]
    #   sw  x12 -> [x10 + (OFF_A_BASE + 4i)]
    for i in range(N):
        P.append(isa.lw(12, 11, A_PACKED_OFF + 4*i))
        P.append(isa.sw(12, OFF_A_BASE + 4*i, 10))

    for i in range(N):
        P.append(isa.lw(12, 11, B_PACKED_OFF + 4*i))
        P.append(isa.sw(12, OFF_B_BASE + 4*i, 10))

    # x13 = 1, write to CTRL
    P.append(isa.addi(13, 0, 1))
    P.append(isa.sw(13, OFF_CTRL, 10))

    # Polling loop: do { x14 = lw [x10 + OFF_STATUS]; x15 = x14 & 2; } while (x15 == 0)
    poll_pc = len(P) * 4    # current PC (in bytes)
    P.append(isa.lw(14, 10, OFF_STATUS))
    P.append(isa.andi(15, 14, 2))
    # beq x15, x0, -8  -> back to lw
    # imm = poll_pc - current_pc = -8 (we are at +0 after andi, so next instr; beq imm uses PC-of-beq)
    P.append(isa.beq(15, 0, -8))   # branch back if status[1]==0

    # Read C[0..15] and store to data SRAM (offset C_RESULT_OFF)
    for i in range(16):
        P.append(isa.lw(12, 10, OFF_C_BASE + 4*i))
        P.append(isa.sw(12, C_RESULT_OFF + 4*i, 11))

    # Halt: jal x0, 0   (infinite loop)
    P.append(isa.jal(0, 0))

    return P


async def reset(dut, cycles: int = 5):
    dut.rst_n.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def imem_load(dut, prog):
    mem = dut.u_imem.u_sram.mem
    for i, w in enumerate(prog):
        mem[i].value = w & 0xFFFFFFFF
    for i in range(len(prog), len(mem)):
        mem[i].value = isa.NOP


def dmem_write_word(dut, byte_off: int, value: int):
    word_idx = byte_off >> 2
    dut.u_dmem.mem[word_idx].value = value & 0xFFFFFFFF


def dmem_read_word(dut, byte_off: int) -> int:
    word_idx = byte_off >> 2
    return int(dut.u_dmem.mem[word_idx].value) & 0xFFFFFFFF


async def run_program(dut, A, B, max_cycles: int = 8000) -> list[list[int]]:
    prog = assemble_program()
    imem_load(dut, prog)

    # Pre-load A and B as packed words in data SRAM
    for i in range(N):
        dmem_write_word(dut, A_PACKED_OFF + 4*i, pack_row(A[i]))
    for i in range(N):
        dmem_write_word(dut, B_PACKED_OFF + 4*i, pack_row(B[i]))
    # zero the result region
    for i in range(16):
        dmem_write_word(dut, C_RESULT_OFF + 4*i, 0)

    await reset(dut)

    # Run until program writes the last result (poll C[15] != 0 won't always be
    # true when expected is zero; instead spin a fixed bound and then read).
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)

    # Read C from data SRAM
    C = [[0]*N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            v = dmem_read_word(dut, C_RESULT_OFF + (i*N + j)*4)
            C[i][j] = s32(v)
    return C


@cocotb.test()
async def smoke_identity(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    A = [[1 if i == j else 0 for j in range(N)] for i in range(N)]
    B = [[i*N + j + 1 for j in range(N)] for i in range(N)]
    C = await run_program(dut, A, B)
    assert C == B, f"identity * B != B\nC: {C}\nB: {B}"


@cocotb.test()
async def random_signed(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    random.seed(0x55)
    fails = []
    for trial in range(5):
        A = [[random.randint(-128, 127) for _ in range(N)] for _ in range(N)]
        B = [[random.randint(-128, 127) for _ in range(N)] for _ in range(N)]
        E = golden(A, B)
        C = await run_program(dut, A, B)
        if C != E:
            fails.append((trial, A, B, E, C))
    assert not fails, (
        f"{len(fails)}/5 mismatched. First: A={fails[0][1]} B={fails[0][2]} "
        f"expected={fails[0][3]} got={fails[0][4]}"
    )
