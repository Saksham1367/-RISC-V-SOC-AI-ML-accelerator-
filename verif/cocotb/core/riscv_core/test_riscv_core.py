"""
End-to-end cocotb test for rtl/core/riscv_core.sv

Builds tiny RV32I programs in memory, runs the core, and checks register-file
contents via hierarchical references (`dut.u_core.u_regfile.regs`).

Tests:
  * arithmetic_smoke: addi/add/sub
  * branch_taken: BEQ taken
  * jal_link: JAL writes PC+4 to rd
  * load_use_stall: LW followed immediately by ADD using loaded value
  * forwarding: back-to-back ADD chain (EX->ID forwarding)
"""

from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from common import rv_isa as isa


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
async def reset(dut, cycles: int = 5):
    dut.rst_n.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def load_program(dut, instructions: list[int], dmem_init: dict[int, int] | None = None):
    """Pre-load IMEM (and optionally DMEM word-addressed) before reset release."""
    imem = dut.u_imem.u_sram.mem
    for i, w in enumerate(instructions):
        imem[i].value = w & 0xFFFFFFFF
    # Pad rest with NOPs so we never run into X-instructions
    for i in range(len(instructions), len(imem)):
        imem[i].value = isa.NOP

    if dmem_init:
        dmem = dut.u_dmem.mem
        for word_idx, val in dmem_init.items():
            dmem[word_idx].value = val & 0xFFFFFFFF


def reg(dut, idx: int) -> int:
    """Read register x<idx> from the regfile (hierarchical)."""
    if idx == 0:
        return 0
    return int(dut.u_core.u_regfile.regs[idx].value) & 0xFFFFFFFF


async def run(dut, cycles: int):
    for _ in range(cycles):
        await RisingEdge(dut.clk)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
@cocotb.test()
async def arithmetic_smoke(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    # Program:
    #   addi x1, x0, 5    # x1 = 5
    #   addi x2, x0, 7    # x2 = 7
    #   add  x3, x1, x2   # x3 = 12
    #   sub  x4, x2, x1   # x4 = 2
    prog = [
        isa.addi(1, 0, 5),
        isa.addi(2, 0, 7),
        isa.add(3, 1, 2),
        isa.sub(4, 2, 1),
    ]
    load_program(dut, prog)
    await reset(dut)
    await run(dut, 30)

    assert reg(dut, 1) == 5,  f"x1: {reg(dut, 1)}"
    assert reg(dut, 2) == 7,  f"x2: {reg(dut, 2)}"
    assert reg(dut, 3) == 12, f"x3: {reg(dut, 3)}"
    assert reg(dut, 4) == 2,  f"x4: {reg(dut, 4)}"


@cocotb.test()
async def forwarding_chain(dut):
    """Back-to-back dependent ALU ops require EX->ID forwarding."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    # x1 = 1; x2 = x1+1; x3 = x2+1; x4 = x3+1
    prog = [
        isa.addi(1, 0, 1),
        isa.addi(2, 1, 1),
        isa.addi(3, 2, 1),
        isa.addi(4, 3, 1),
    ]
    load_program(dut, prog)
    await reset(dut)
    await run(dut, 30)

    assert reg(dut, 1) == 1
    assert reg(dut, 2) == 2
    assert reg(dut, 3) == 3
    assert reg(dut, 4) == 4


@cocotb.test()
async def branch_taken(dut):
    """BEQ taken should skip the next instruction."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    # 0x00: addi x1, x0, 3
    # 0x04: addi x2, x0, 3
    # 0x08: beq  x1, x2, +8       ; jumps to 0x10
    # 0x0C: addi x3, x0, 99       ; SHOULD NOT execute
    # 0x10: addi x4, x0, 42
    prog = [
        isa.addi(1, 0, 3),
        isa.addi(2, 0, 3),
        isa.beq(1, 2, 8),
        isa.addi(3, 0, 99),
        isa.addi(4, 0, 42),
    ]
    load_program(dut, prog)
    await reset(dut)
    await run(dut, 40)

    assert reg(dut, 1) == 3
    assert reg(dut, 2) == 3
    assert reg(dut, 3) == 0,  f"x3 should be 0 (skipped), got {reg(dut, 3)}"
    assert reg(dut, 4) == 42


@cocotb.test()
async def branch_not_taken(dut):
    """BNE not taken — both instructions execute."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    # x1=5; x2=5; bne x1,x2,+8 (NOT taken); x3=10; x4=20
    prog = [
        isa.addi(1, 0, 5),
        isa.addi(2, 0, 5),
        isa.bne(1, 2, 8),
        isa.addi(3, 0, 10),
        isa.addi(4, 0, 20),
    ]
    load_program(dut, prog)
    await reset(dut)
    await run(dut, 40)

    assert reg(dut, 3) == 10
    assert reg(dut, 4) == 20


@cocotb.test()
async def jal_link(dut):
    """JAL must write PC+4 to rd and jump."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    # 0x00: addi x1, x0, 1
    # 0x04: jal  x5, +8           ; rd=x5 = 0x08, target = 0x0C
    # 0x08: addi x2, x0, 99       ; SHOULD NOT execute
    # 0x0C: addi x3, x0, 7
    prog = [
        isa.addi(1, 0, 1),
        isa.jal(5, 8),
        isa.addi(2, 0, 99),
        isa.addi(3, 0, 7),
    ]
    load_program(dut, prog)
    await reset(dut)
    await run(dut, 40)

    assert reg(dut, 1) == 1
    assert reg(dut, 5) == 0x08, f"x5 (link): {reg(dut, 5):08x}"
    assert reg(dut, 2) == 0,    f"x2: jumped over but got {reg(dut, 2)}"
    assert reg(dut, 3) == 7


@cocotb.test()
async def load_store_word(dut):
    """SW then LW — basic data path through DMEM."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    # x1 = 0x10000000  (data SRAM base — but our TB ignores high bits, sram is 4K words)
    # We'll use a small dmem index instead. Use addr 0 of dmem.
    # x2 = 0xDEADBEEF; sw x2, 0(x0); lw x3, 0(x0); should give x3 == x2.
    #
    # Build 0xDEADBEEF in two halves: lui x2, 0xDEADC; addi x2, x2, -273  (to land on 0xDEADBEEF)
    # Simpler: lui x2, 0xDEADB; addi x2, x2, 0xeef (sign-extends though — use ori)
    # Cleanest: lui x2, 0xDEADC; addi x2, x2, -273   ; 0xDEADC000 + (-273) = 0xDEADBEEF
    prog = [
        isa.lui(2, 0xDEADC000),
        isa.addi(2, 2, -273 & 0xFFF),
        isa.sw(2, 0, 0),
        isa.lw(3, 0, 0),
    ]
    load_program(dut, prog)
    await reset(dut)
    await run(dut, 40)

    assert reg(dut, 2) == 0xDEADBEEF, f"x2 build: 0x{reg(dut, 2):08x}"
    assert reg(dut, 3) == 0xDEADBEEF, f"x3 load:  0x{reg(dut, 3):08x}"


@cocotb.test()
async def load_use_stall(dut):
    """LW followed immediately by an op consuming the loaded value must stall 1 cycle."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    # Pre-load DMEM[0] = 0x11
    # lw  x1, 0(x0)
    # add x2, x1, x1     ; consumer of x1
    # add x3, x2, x2
    prog = [
        isa.lw(1, 0, 0),
        isa.add(2, 1, 1),
        isa.add(3, 2, 2),
    ]
    load_program(dut, prog, dmem_init={0: 0x11})
    await reset(dut)
    await run(dut, 40)

    assert reg(dut, 1) == 0x11
    assert reg(dut, 2) == 0x22, f"x2: 0x{reg(dut, 2):08x}"
    assert reg(dut, 3) == 0x44, f"x3: 0x{reg(dut, 3):08x}"


@cocotb.test()
async def x0_stays_zero(dut):
    """Writing to x0 should be a no-op."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    prog = [
        isa.addi(0, 0, 0x123),    # try to set x0 = 0x123
        isa.add(1, 0, 0),         # x1 = x0 + x0
    ]
    load_program(dut, prog)
    await reset(dut)
    await run(dut, 30)

    assert reg(dut, 0) == 0
    assert reg(dut, 1) == 0
