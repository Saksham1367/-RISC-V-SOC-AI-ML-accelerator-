"""
Cocotb unit test for rtl/core/alu.sv

Drives a directed sweep across every ALU op + a constrained-random batch,
checking against the golden Python model.
"""

from __future__ import annotations

import random

import cocotb
from cocotb.triggers import Timer

from common.golden import alu_model, MASK32, to_signed


# Must mirror the alu_op_e enum order in riscv_pkg.sv
OP_CODES = {
    "add":    0,
    "sub":    1,
    "and":    2,
    "or":     3,
    "xor":    4,
    "sll":    5,
    "srl":    6,
    "sra":    7,
    "slt":    8,
    "sltu":   9,
    "pass_b": 10,
}


async def apply(dut, op_name: str, a: int, b: int):
    dut.a.value  = a & MASK32
    dut.b.value  = b & MASK32
    dut.op.value = OP_CODES[op_name]
    await Timer(1, units="ns")


def check(dut, op_name: str, a: int, b: int):
    expected = alu_model(op_name, a, b)
    actual   = int(dut.y.value) & MASK32
    assert actual == expected, (
        f"[{op_name}] a=0x{a:08x} b=0x{b:08x} "
        f"expected 0x{expected:08x} got 0x{actual:08x}"
    )
    if op_name not in ("slt", "sltu"):
        zero_expected = 1 if expected == 0 else 0
        zero_actual   = int(dut.zero.value)
        assert zero_actual == zero_expected, (
            f"[{op_name}] zero flag mismatch: expected {zero_expected} got {zero_actual}"
        )


@cocotb.test()
async def directed_basics(dut):
    """Hit each op with hand-picked, easy-to-debug operands."""
    cases = [
        ("add",    1, 2),
        ("add",    0xFFFFFFFF, 1),                # overflow wraps to 0
        ("sub",    5, 5),
        ("sub",    0, 1),                         # underflow -> 0xFFFFFFFF
        ("and",    0xF0F0F0F0, 0x0F0F0F0F),
        ("or",     0xF0F0F0F0, 0x0F0F0F0F),
        ("xor",    0xAAAAAAAA, 0x55555555),
        ("sll",    1, 31),
        ("srl",    0x80000000, 1),
        ("sra",    0x80000000, 1),                # sign-extend
        ("slt",    0xFFFFFFFF, 1),                # -1 < 1 (signed) -> 1
        ("slt",    1, 0xFFFFFFFF),                # 1 < -1 -> 0
        ("sltu",   1, 0xFFFFFFFF),                # 1 < big -> 1
        ("sltu",   0xFFFFFFFF, 1),                # big < 1 -> 0
        ("pass_b", 0xDEAD_BEEF, 0x1234_5678),
    ]
    for op, a, b in cases:
        await apply(dut, op, a, b)
        check(dut, op, a, b)


@cocotb.test()
async def random_sweep(dut):
    """Constrained-random across all ops."""
    random.seed(0xC0FFEE)
    N = 500
    ops = list(OP_CODES.keys())
    for _ in range(N):
        op = random.choice(ops)
        a = random.randint(0, MASK32)
        b = random.randint(0, MASK32)
        await apply(dut, op, a, b)
        check(dut, op, a, b)


@cocotb.test()
async def shift_amount_masking(dut):
    """Shift ops must use only b[4:0] regardless of upper bits."""
    for sh in range(0, 32):
        b = sh | 0xFFFFFFE0  # garbage in high bits, sh in low 5
        await apply(dut, "sll", 0x1, b)
        check(dut, "sll", 0x1, b)
        await apply(dut, "srl", 0x80000000, b)
        check(dut, "srl", 0x80000000, b)
        await apply(dut, "sra", 0x80000000, b)
        check(dut, "sra", 0x80000000, b)
