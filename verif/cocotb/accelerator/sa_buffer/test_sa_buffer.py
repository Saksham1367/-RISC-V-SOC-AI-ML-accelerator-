"""
Cocotb integration test for rtl/accelerator/sa_buffer.sv (which wraps sa_top).

Drives matrix multiply C = A * B with random INT8 matrices, checks against
a NumPy golden model.
"""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False


N = 4


def s32(x: int) -> int:
    x &= 0xFFFFFFFF
    return x - 0x100000000 if x & 0x80000000 else x


def golden_matmul(A: list[list[int]], B: list[list[int]]) -> list[list[int]]:
    """C = A * B, INT8 inputs, INT32 accumulator (Python ints — no overflow)."""
    if HAS_NUMPY:
        a = np.array(A, dtype=np.int64)
        b = np.array(B, dtype=np.int64)
        return (a @ b).tolist()
    # fallback: pure-Python implementation
    C = [[0] * N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            s = 0
            for k in range(N):
                s += A[i][k] * B[k][j]
            C[i][j] = s
    return C


async def reset(dut, cycles: int = 3):
    dut.rst_n.value = 0
    dut.start.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def load_matrices(dut, A, B):
    for i in range(N):
        for j in range(N):
            dut.a_mat[i * N + j].value = A[i][j] & 0xFF
            dut.b_mat[i * N + j].value = B[i][j] & 0xFF


def read_result(dut):
    C = [[0] * N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            C[i][j] = s32(int(dut.c_mat[i * N + j].value))
    return C


async def run_one(dut, A, B):
    load_matrices(dut, A, B)
    await Timer(1, unit="ns")
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    # wait for done with a generous timeout
    for _ in range(200):
        await RisingEdge(dut.clk)
        if int(dut.done.value) == 1:
            break
    else:
        raise TimeoutError("sa_buffer never asserted done")

    return read_result(dut)


def fmt(M):
    return "\n".join(" ".join(f"{v:6d}" for v in row) for row in M)


@cocotb.test()
async def small_known(dut):
    """Small known multiply: identity * something."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    A = [[1 if i == j else 0 for j in range(N)] for i in range(N)]    # identity
    B = [[i * N + j + 1 for j in range(N)] for i in range(N)]         # 1..16

    C = await run_one(dut, A, B)
    assert C == B, f"identity * B should equal B\nB:\n{fmt(B)}\nC:\n{fmt(C)}"


@cocotb.test()
async def zero_matrix(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    A = [[0] * N for _ in range(N)]
    B = [[(i + j) % 100 for j in range(N)] for i in range(N)]
    C = await run_one(dut, A, B)
    assert all(v == 0 for row in C for v in row)


@cocotb.test()
async def small_signed(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    A = [
        [ 1, -1,  2, -2],
        [-3,  3,  0,  0],
        [ 4, -4,  1, -1],
        [ 0,  0,  5, -5],
    ]
    B = [
        [ 1,  2,  3,  4],
        [-1, -2, -3, -4],
        [ 0,  1,  0, -1],
        [ 1,  0, -1,  0],
    ]
    expected = golden_matmul(A, B)
    C = await run_one(dut, A, B)
    assert C == expected, f"\nA:\n{fmt(A)}\nB:\n{fmt(B)}\nexpected:\n{fmt(expected)}\nC:\n{fmt(C)}"


@cocotb.test()
async def random_full_range(dut):
    """Random INT8 matrices — 30 iterations against NumPy golden."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    random.seed(0xABCD)
    fails = []
    for trial in range(30):
        A = [[random.randint(-128, 127) for _ in range(N)] for _ in range(N)]
        B = [[random.randint(-128, 127) for _ in range(N)] for _ in range(N)]
        expected = golden_matmul(A, B)
        C = await run_one(dut, A, B)
        if C != expected:
            fails.append((trial, A, B, expected, C))

    if fails:
        t, A, B, E, C = fails[0]
        msg = (
            f"{len(fails)}/30 random matmuls mismatched. First failure (trial {t}):\n"
            f"A:\n{fmt(A)}\nB:\n{fmt(B)}\nexpected:\n{fmt(E)}\ngot:\n{fmt(C)}"
        )
        assert False, msg


@cocotb.test()
async def back_to_back(dut):
    """Two operations in a row — second must accumulate from zero, not add to first."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    A1 = [[1] * N for _ in range(N)]
    B1 = [[2] * N for _ in range(N)]
    A2 = [[3] * N for _ in range(N)]
    B2 = [[4] * N for _ in range(N)]

    C1 = await run_one(dut, A1, B1)
    C2 = await run_one(dut, A2, B2)
    assert C1 == golden_matmul(A1, B1), f"C1: {C1}"
    assert C2 == golden_matmul(A2, B2), f"C2: {C2}"
