"""
RV32M cocotb tests for the 5-stage RV32IM core.

Verifies all 8 M-extension instructions against a Python golden model:
  MUL / MULH / MULHSU / MULHU         (single-cycle in ALU)
  DIV / DIVU / REM / REMU             (iterative div32, ~33 cycles)

Edge cases tested:
  * Divide-by-zero (DIV -> -1, DIVU -> all-ones, REM/REMU -> dividend)
  * Signed overflow (INT_MIN / -1 -> DIV=INT_MIN, REM=0)
  * MIN, MAX, mixed signs, zeros
  * Back-to-back DIV ops (FSM IDLE/RUN/DONE handshake reuse)
  * DIV result consumed by next instruction (forwarding through MEM/WB stage)
"""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from common import rv_isa as isa


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
MASK32 = (1 << 32) - 1


def to_s32(x: int) -> int:
    x &= MASK32
    return x - (1 << 32) if x & (1 << 31) else x


def to_u32(x: int) -> int:
    return x & MASK32


def s64(x: int) -> int:
    x &= (1 << 64) - 1
    return x - (1 << 64) if x & (1 << 63) else x


# ---------------------------------------------------------------------------
# Python golden models (mirror the spec exactly, including edge cases)
# ---------------------------------------------------------------------------
def golden_mul(a: int, b: int) -> int:
    p = (to_s32(a) * to_s32(b)) & ((1 << 64) - 1)
    return p & MASK32


def golden_mulh(a: int, b: int) -> int:
    p = (to_s32(a) * to_s32(b)) & ((1 << 64) - 1)
    return (p >> 32) & MASK32


def golden_mulhsu(a: int, b: int) -> int:
    # signed rs1 * unsigned rs2
    s_rs1 = to_s32(a)
    u_rs2 = to_u32(b)
    p = (s_rs1 * u_rs2) & ((1 << 65) - 1)  # 33+32 bits
    return (p >> 32) & MASK32


def golden_mulhu(a: int, b: int) -> int:
    p = to_u32(a) * to_u32(b)
    return (p >> 32) & MASK32


def golden_div(a: int, b: int) -> int:
    if to_u32(b) == 0:
        return MASK32  # -1
    if to_s32(a) == -(1 << 31) and to_s32(b) == -1:
        return 1 << 31  # INT_MIN
    s_a, s_b = to_s32(a), to_s32(b)
    # Truncated toward zero (RISC-V spec)
    q = abs(s_a) // abs(s_b)
    if (s_a < 0) ^ (s_b < 0):
        q = -q
    return q & MASK32


def golden_divu(a: int, b: int) -> int:
    if to_u32(b) == 0:
        return MASK32
    return (to_u32(a) // to_u32(b)) & MASK32


def golden_rem(a: int, b: int) -> int:
    if to_u32(b) == 0:
        return to_u32(a)
    if to_s32(a) == -(1 << 31) and to_s32(b) == -1:
        return 0
    s_a, s_b = to_s32(a), to_s32(b)
    r = abs(s_a) % abs(s_b)
    if s_a < 0:
        r = -r
    return r & MASK32


def golden_remu(a: int, b: int) -> int:
    if to_u32(b) == 0:
        return to_u32(a)
    return (to_u32(a) % to_u32(b)) & MASK32


# ---------------------------------------------------------------------------
# Cocotb runtime helpers (copied from test_riscv_core.py pattern)
# ---------------------------------------------------------------------------
async def reset(dut, cycles: int = 5):
    dut.rst_n.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def load_program(dut, instructions: list[int]):
    imem = dut.u_imem.u_sram.mem
    for i, w in enumerate(instructions):
        imem[i].value = w & MASK32
    for i in range(len(instructions), len(imem)):
        imem[i].value = isa.NOP


def reg(dut, idx: int) -> int:
    if idx == 0:
        return 0
    return int(dut.u_core.u_regfile.regs[idx].value) & MASK32


async def run(dut, cycles: int):
    for _ in range(cycles):
        await RisingEdge(dut.clk)


# ---------------------------------------------------------------------------
# Builders: load a 32-bit immediate into a register using LUI + ADDI
# ---------------------------------------------------------------------------
def li32(rd: int, imm: int) -> list[int]:
    """Load a 32-bit value into rd using LUI + ADDI (handling sign extension)."""
    imm &= MASK32
    upper = (imm + 0x800) & 0xFFFFF000  # round to upper 20 bits
    lower = imm - upper
    if lower & 0x800:  # sign-extend lower 12 bits
        lower -= 0x1000
    insns = []
    if upper:
        insns.append(isa.lui(rd, upper))
        if lower:
            insns.append(isa.addi(rd, rd, lower))
    else:
        insns.append(isa.addi(rd, 0, lower))
    return insns


# ---------------------------------------------------------------------------
# Tests — MUL family (single-cycle, identical timing to ALU ops)
# ---------------------------------------------------------------------------
@cocotb.test()
async def mul_directed(dut):
    """MUL/MULH/MULHU/MULHSU on a fixed set of edge-case operand pairs."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    pairs = [
        (3, 4),
        (0xFFFFFFFF, 0xFFFFFFFF),       # -1 * -1 = 1
        (0x7FFFFFFF, 2),                # MAX_INT * 2 → high bit set
        (0x80000000, 0xFFFFFFFF),       # INT_MIN * -1
        (0x12345678, 0x9ABCDEF0),
        (0x80000000, 0x80000000),       # INT_MIN * INT_MIN
    ]

    for a, b in pairs:
        prog = []
        prog += li32(1, a)              # x1 = a
        prog += li32(2, b)              # x2 = b
        prog.append(isa.mul   (10, 1, 2))
        prog.append(isa.mulh  (11, 1, 2))
        prog.append(isa.mulhsu(12, 1, 2))
        prog.append(isa.mulhu (13, 1, 2))

        load_program(dut, prog)
        await reset(dut)
        await run(dut, 60)              # plenty of time for pipeline to drain

        assert reg(dut, 1)  == to_u32(a),                f"x1 (a)={reg(dut,1):#x} expected {a:#x}"
        assert reg(dut, 2)  == to_u32(b),                f"x2 (b)={reg(dut,2):#x} expected {b:#x}"
        assert reg(dut, 10) == golden_mul   (a, b),      f"MUL  ({a:#x},{b:#x}) got {reg(dut,10):#x} expected {golden_mul(a,b):#x}"
        assert reg(dut, 11) == golden_mulh  (a, b),      f"MULH ({a:#x},{b:#x}) got {reg(dut,11):#x} expected {golden_mulh(a,b):#x}"
        assert reg(dut, 12) == golden_mulhsu(a, b),      f"MULHSU ({a:#x},{b:#x}) got {reg(dut,12):#x} expected {golden_mulhsu(a,b):#x}"
        assert reg(dut, 13) == golden_mulhu (a, b),      f"MULHU ({a:#x},{b:#x}) got {reg(dut,13):#x} expected {golden_mulhu(a,b):#x}"


@cocotb.test()
async def mul_random(dut):
    """30 random operand pairs through all four MUL variants."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(0xBEEF)

    for _ in range(30):
        a = rng.randint(0, MASK32)
        b = rng.randint(0, MASK32)

        prog = []
        prog += li32(1, a)
        prog += li32(2, b)
        prog.append(isa.mul   (10, 1, 2))
        prog.append(isa.mulh  (11, 1, 2))
        prog.append(isa.mulhsu(12, 1, 2))
        prog.append(isa.mulhu (13, 1, 2))

        load_program(dut, prog)
        await reset(dut)
        await run(dut, 60)

        assert reg(dut, 10) == golden_mul   (a, b)
        assert reg(dut, 11) == golden_mulh  (a, b)
        assert reg(dut, 12) == golden_mulhsu(a, b)
        assert reg(dut, 13) == golden_mulhu (a, b)


# ---------------------------------------------------------------------------
# Tests — DIV family (iterative, ~33 cycles + handshake)
# ---------------------------------------------------------------------------
@cocotb.test()
async def div_directed(dut):
    """All 4 divide ops on a fixed set of edge-case operand pairs."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    pairs = [
        (10, 3),
        (-10 & MASK32, 3),                  # -10 / 3
        (10, -3 & MASK32),                  # 10 / -3
        (-10 & MASK32, -3 & MASK32),        # -10 / -3
        (0x80000000, 0xFFFFFFFF),           # INT_MIN / -1 (overflow)
        (5, 0),                             # divide by zero
        (0, 7),
        (0xFFFFFFFE, 2),                    # -2 / 2 = -1
        (0x7FFFFFFF, 1),                    # MAX_INT / 1
        (0xFFFFFFFF, 0xFFFFFFFE),           # -1 / -2 = 0 (signed); 4294967295/4294967294=1 (unsigned)
    ]

    for a, b in pairs:
        prog = []
        prog += li32(1, a)
        prog += li32(2, b)
        prog.append(isa.div (10, 1, 2))
        prog.append(isa.divu(11, 1, 2))
        prog.append(isa.rem (12, 1, 2))
        prog.append(isa.remu(13, 1, 2))

        load_program(dut, prog)
        await reset(dut)
        # 4 divides * ~33 cycles each + pipeline drain ≈ 200 cycles. Be generous.
        await run(dut, 250)

        exp_div  = golden_div (a, b)
        exp_divu = golden_divu(a, b)
        exp_rem  = golden_rem (a, b)
        exp_remu = golden_remu(a, b)

        got_div  = reg(dut, 10)
        got_divu = reg(dut, 11)
        got_rem  = reg(dut, 12)
        got_remu = reg(dut, 13)

        assert got_div  == exp_div,  f"DIV  ({a:#x},{b:#x}) got {got_div:#x} expected {exp_div:#x}"
        assert got_divu == exp_divu, f"DIVU ({a:#x},{b:#x}) got {got_divu:#x} expected {exp_divu:#x}"
        assert got_rem  == exp_rem,  f"REM  ({a:#x},{b:#x}) got {got_rem:#x} expected {exp_rem:#x}"
        assert got_remu == exp_remu, f"REMU ({a:#x},{b:#x}) got {got_remu:#x} expected {exp_remu:#x}"


@cocotb.test()
async def div_random(dut):
    """20 random operand pairs through all four DIV variants."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(0xC0FFEE)

    for _ in range(20):
        a = rng.randint(0, MASK32)
        b = rng.randint(0, MASK32)

        prog = []
        prog += li32(1, a)
        prog += li32(2, b)
        prog.append(isa.div (10, 1, 2))
        prog.append(isa.divu(11, 1, 2))
        prog.append(isa.rem (12, 1, 2))
        prog.append(isa.remu(13, 1, 2))

        load_program(dut, prog)
        await reset(dut)
        await run(dut, 250)

        assert reg(dut, 10) == golden_div (a, b)
        assert reg(dut, 11) == golden_divu(a, b)
        assert reg(dut, 12) == golden_rem (a, b)
        assert reg(dut, 13) == golden_remu(a, b)


@cocotb.test()
async def div_then_use(dut):
    """DIV result consumed by the very next instruction — forwarding via
    MEM/WB or WB->EX path. This stresses the divider's ack handshake AND
    the forwarding muxes simultaneously."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # x1 = 100; x2 = 7; x3 = x1 / x2 = 14;
    # x4 = x3 + 1 (DIV -> EX forwarding)
    # x5 = x4 * 2 (chained MUL after the forwarded ADD)
    prog = []
    prog += li32(1, 100)
    prog += li32(2, 7)
    prog.append(isa.div(3, 1, 2))     # x3 = 14
    prog.append(isa.addi(4, 3, 1))    # x4 = 15
    prog.append(isa.addi(20, 0, 2))   # x20 = 2
    prog.append(isa.mul(5, 4, 20))    # x5 = 30

    load_program(dut, prog)
    await reset(dut)
    await run(dut, 100)

    assert reg(dut, 3) == 14, f"x3 = {reg(dut, 3)}"
    assert reg(dut, 4) == 15, f"x4 = {reg(dut, 4)}"
    assert reg(dut, 5) == 30, f"x5 = {reg(dut, 5)}"


@cocotb.test()
async def back_to_back_div(dut):
    """Two divides in immediate succession — stresses div32 FSM idle/run/done
    re-entry. Uses different operands to ensure each result is fresh."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # 100/3 = 33,  77/11 = 7,  1024/4 = 256
    prog = []
    prog += li32(1, 100)
    prog += li32(2, 3)
    prog.append(isa.div(10, 1, 2))      # x10 = 33
    prog += li32(3, 77)
    prog += li32(4, 11)
    prog.append(isa.div(11, 3, 4))      # x11 = 7
    prog += li32(5, 1024)
    prog += li32(6, 4)
    prog.append(isa.div(12, 5, 6))      # x12 = 256

    load_program(dut, prog)
    await reset(dut)
    await run(dut, 250)

    assert reg(dut, 10) == 33,   f"x10 = {reg(dut, 10)}"
    assert reg(dut, 11) == 7,    f"x11 = {reg(dut, 11)}"
    assert reg(dut, 12) == 256,  f"x12 = {reg(dut, 12)}"
