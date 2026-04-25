"""
Cocotb unit test for rtl/core/imm_gen.sv

Builds instructions for each format using the encoder in common/rv_isa.py
and checks the immediate the RTL extracts matches.
"""

from __future__ import annotations

import random

import cocotb
from cocotb.triggers import Timer

from common import rv_isa as isa
from common.golden import to_signed, MASK32


async def drive(dut, instr: int) -> int:
    dut.instr.value = instr
    await Timer(1, unit="ns")
    return int(dut.imm.value)


@cocotb.test()
async def i_type(dut):
    """ADDI/LW/JALR — sign-extended 12-bit imm."""
    for imm in [-2048, -1, 0, 1, 100, 2047]:
        instr = isa.addi(rd=1, rs1=2, imm=imm & 0xFFF)
        got = await drive(dut, instr)
        assert to_signed(got) == imm, f"I-type imm: expected {imm} got {to_signed(got)}"


@cocotb.test()
async def s_type(dut):
    """SW imm encoding."""
    for imm in [-2048, -1, 0, 4, 100, 2047]:
        instr = isa.sw(rs2=3, imm=imm & 0xFFF, rs1=2)
        got = await drive(dut, instr)
        assert to_signed(got) == imm, f"S-type imm: expected {imm} got {to_signed(got)}"


@cocotb.test()
async def b_type(dut):
    """Branch imm — multiples of 2, signed 13-bit."""
    for imm in [-4096, -8, -2, 0, 4, 100, 4094]:
        instr = isa.beq(rs1=1, rs2=2, imm=imm & 0x1FFF)
        got = await drive(dut, instr)
        assert to_signed(got) == imm, f"B-type imm: expected {imm} got {to_signed(got)}"


@cocotb.test()
async def u_type(dut):
    """LUI / AUIPC — upper 20 bits, low 12 zero."""
    for imm20 in [0, 0x12345, 0xFFFFF, 0xABCDE]:
        full = (imm20 << 12) & 0xFFFFFFFF
        instr = isa.lui(rd=1, imm=full)
        got = await drive(dut, instr)
        assert got == full, f"U-type lui imm: expected 0x{full:08x} got 0x{got:08x}"

        instr = isa.auipc(rd=1, imm=full)
        got = await drive(dut, instr)
        assert got == full, f"U-type auipc imm: expected 0x{full:08x} got 0x{got:08x}"


@cocotb.test()
async def j_type(dut):
    """JAL — multiples of 2, signed 21-bit."""
    for imm in [-1048576, -4, 0, 4, 100, 1048574]:
        instr = isa.jal(rd=1, imm=imm & 0x1FFFFF)
        got = await drive(dut, instr)
        assert to_signed(got) == imm, f"J-type imm: expected {imm} got {to_signed(got)}"


@cocotb.test()
async def random_storm(dut):
    random.seed(0x1234)
    formats = [
        ("addi",  lambda v: isa.addi(1, 2, v & 0xFFF),       lambda v: to_signed(v, 12)),
        ("sw",    lambda v: isa.sw(3, v & 0xFFF, 2),         lambda v: to_signed(v, 12)),
        ("beq",   lambda v: isa.beq(1, 2, v & 0x1FFE),       lambda v: to_signed(v & 0x1FFE, 13)),
        ("lui",   lambda v: isa.lui(1, (v & 0xFFFFF) << 12), lambda v: ((v & 0xFFFFF) << 12) & 0xFFFFFFFF),
        ("jal",   lambda v: isa.jal(1, v & 0x1FFFFE),        lambda v: to_signed(v & 0x1FFFFE, 21)),
    ]

    for _ in range(200):
        name, build, expect = random.choice(formats)
        v = random.randint(-(1 << 20), (1 << 20) - 1)
        instr = build(v)
        got = await drive(dut, instr)
        if name == "lui":
            exp = expect(v)
            assert got == exp, f"{name}: expected 0x{exp:08x} got 0x{got:08x}"
        else:
            exp = expect(v)
            assert to_signed(got) == exp, (
                f"{name} v={v}: expected {exp} got {to_signed(got)}"
            )
