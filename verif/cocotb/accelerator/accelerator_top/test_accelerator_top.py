"""
Cocotb integration test for rtl/accelerator/accelerator_top.sv

Drives a full matrix-multiply through the AXI4-Lite slave port:
  1. Write A and B (4 rows of packed INT8 each)
  2. Write CTRL[0]=1 (start)
  3. Poll STATUS until done
  4. Read back C (16 INT32 words) and compare to NumPy golden

Memory map (offsets):
  0x000 CTRL
  0x004 STATUS
  0x008 MATRIX_SIZE
  0x010..0x01C  A_ROW0..3
  0x020..0x02C  B_ROW0..3
  0x030..0x06C  C[0..15]
"""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from common.axil import AxiLiteMaster

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False


N = 4

OFF_CTRL    = 0x00
OFF_STATUS  = 0x04
OFF_SIZE    = 0x08
OFF_A_BASE  = 0x10  # +i*4 for row i
OFF_B_BASE  = 0x20  # +i*4 for row i
OFF_C_BASE  = 0x30  # +k*4 for k in 0..15 (i*N+j)


def s8(x):  return x - 0x100 if x & 0x80 else x
def s32(x):
    x &= 0xFFFFFFFF
    return x - 0x100000000 if x & 0x80000000 else x


def pack_row(row):
    """4 INT8 -> 32-bit word, col 0 in LSB."""
    return ((row[3] & 0xFF) << 24) | ((row[2] & 0xFF) << 16) | \
           ((row[1] & 0xFF) << 8)  |  (row[0] & 0xFF)


def golden(A, B):
    if HAS_NUMPY:
        return (np.array(A, dtype=np.int64) @ np.array(B, dtype=np.int64)).tolist()
    C = [[0]*N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            C[i][j] = sum(A[i][k] * B[k][j] for k in range(N))
    return C


async def reset(dut, cycles: int = 4):
    dut.rst_n.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_matmul(dut, m, A, B):
    # Load operands
    for i in range(N):
        await m.write(OFF_A_BASE + i*4, pack_row(A[i]))
    for i in range(N):
        await m.write(OFF_B_BASE + i*4, pack_row(B[i]))
    # Start
    await m.write(OFF_CTRL, 0x1)
    # Poll done
    for _ in range(200):
        s = await m.read(OFF_STATUS)
        if s & 0x2:
            break
    else:
        raise TimeoutError("done never asserted")
    # Read C
    C = [[0]*N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            v = await m.read(OFF_C_BASE + (i*N + j)*4)
            C[i][j] = s32(v)
    return C


@cocotb.test()
async def identity_matmul(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    m = AxiLiteMaster(dut)

    A = [[1 if i == j else 0 for j in range(N)] for i in range(N)]
    B = [[i*N + j + 1 for j in range(N)] for i in range(N)]
    C = await run_matmul(dut, m, A, B)
    assert C == B, f"identity * B != B: {C}"


@cocotb.test()
async def random_signed(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    m = AxiLiteMaster(dut)
    random.seed(0x511)

    fails = []
    for trial in range(10):
        A = [[random.randint(-128, 127) for _ in range(N)] for _ in range(N)]
        B = [[random.randint(-128, 127) for _ in range(N)] for _ in range(N)]
        E = golden(A, B)
        C = await run_matmul(dut, m, A, B)
        if C != E:
            fails.append((trial, A, B, E, C))
    assert not fails, (
        f"{len(fails)}/10 mismatched. First: A={fails[0][1]} B={fails[0][2]} "
        f"E={fails[0][3]} C={fails[0][4]}"
    )


@cocotb.test()
async def back_to_back(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    m = AxiLiteMaster(dut)

    A1 = [[1]*N for _ in range(N)]
    B1 = [[2]*N for _ in range(N)]
    A2 = [[-1]*N for _ in range(N)]
    B2 = [[3]*N for _ in range(N)]

    C1 = await run_matmul(dut, m, A1, B1)
    C2 = await run_matmul(dut, m, A2, B2)
    assert C1 == golden(A1, B1)
    assert C2 == golden(A2, B2)
