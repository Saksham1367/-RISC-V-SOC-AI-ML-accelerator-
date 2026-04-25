"""
Pure-Python golden reference helpers for the RV32I core.

Used by cocotb scoreboards to predict expected results.
"""

from __future__ import annotations

MASK32 = 0xFFFFFFFF


def to_signed(x: int, bits: int = 32) -> int:
    x &= (1 << bits) - 1
    if x & (1 << (bits - 1)):
        x -= 1 << bits
    return x


def alu_model(op: str, a: int, b: int) -> int:
    """Mirrors the RTL ALU. op is one of: add, sub, and, or, xor,
    sll, srl, sra, slt, sltu, pass_b."""
    a &= MASK32
    b &= MASK32
    if op == "add":   return (a + b) & MASK32
    if op == "sub":   return (a - b) & MASK32
    if op == "and":   return (a & b) & MASK32
    if op == "or":    return (a | b) & MASK32
    if op == "xor":   return (a ^ b) & MASK32
    if op == "sll":   return (a << (b & 0x1F)) & MASK32
    if op == "srl":   return (a >> (b & 0x1F)) & MASK32
    if op == "sra":
        sa = to_signed(a, 32)
        return (sa >> (b & 0x1F)) & MASK32
    if op == "slt":   return 1 if to_signed(a) < to_signed(b) else 0
    if op == "sltu":  return 1 if a < b else 0
    if op == "pass_b": return b
    raise ValueError(f"unknown alu op: {op}")


def branch_taken(br: str, a: int, b: int) -> bool:
    a &= MASK32
    b &= MASK32
    if br == "eq":  return a == b
    if br == "ne":  return a != b
    if br == "lt":  return to_signed(a) < to_signed(b)
    if br == "ge":  return to_signed(a) >= to_signed(b)
    if br == "ltu": return a < b
    if br == "geu": return a >= b
    if br == "jal": return True
    raise ValueError(f"unknown branch type: {br}")
