"""
Forwarding-path coverage for the 5-stage pipeline.

These tests stress each of the three forward sources:
  * MEM -> EX  (priority): one instruction ahead in the pipeline
  * WB  -> EX             : two instructions ahead
  * regfile (no forward)  : enough delay slots that the value is committed

Specifically exercised:
  * Single-cycle ALU producer feeding the very next instruction
  * Producer two ahead of consumer (WB->EX path)
  * Load consumed by the very next instruction (single-cycle SRAM means
    MEM->EX picks up load_aligned combinationally — no stall needed)
  * Load consumed two instructions later (WB->EX of load_aligned)
  * Three-deep dependency chain
  * x0 ignored as forwarding destination (writes to x0 never forward)
"""

from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from common import rv_isa as isa


MASK32 = (1 << 32) - 1


async def reset(dut, cycles: int = 5):
    dut.rst_n.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def load_program(dut, instructions: list[int], dmem_init=None):
    imem = dut.u_imem.u_sram.mem
    for i, w in enumerate(instructions):
        imem[i].value = w & MASK32
    for i in range(len(instructions), len(imem)):
        imem[i].value = isa.NOP

    if dmem_init:
        dmem = dut.u_dmem.mem
        for word_idx, val in dmem_init.items():
            dmem[word_idx].value = val & MASK32


def reg(dut, idx: int) -> int:
    if idx == 0:
        return 0
    return int(dut.u_core.u_regfile.regs[idx].value) & MASK32


async def run(dut, cycles: int):
    for _ in range(cycles):
        await RisingEdge(dut.clk)


# ---------------------------------------------------------------------------
@cocotb.test()
async def fwd_mem_to_ex_alu(dut):
    """ADD producer immediately feeds ADD consumer — MEM->EX of ALU result."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # x1 = 5
    # x2 = x1 + 7   (consumer reads x1; producer is one ahead — MEM->EX)
    # x3 = x2 + 1   (consumer reads x2; producer is one ahead — MEM->EX)
    prog = [
        isa.addi(1, 0, 5),
        isa.addi(2, 1, 7),
        isa.addi(3, 2, 1),
    ]
    load_program(dut, prog)
    await reset(dut)
    await run(dut, 30)

    assert reg(dut, 1) == 5
    assert reg(dut, 2) == 12
    assert reg(dut, 3) == 13


@cocotb.test()
async def fwd_wb_to_ex_alu(dut):
    """Producer two ahead of consumer — WB->EX path (with one NOP in between)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # x1 = 9
    # nop
    # x2 = x1 + 1   (consumer reads x1; producer two ahead — WB->EX)
    prog = [
        isa.addi(1, 0, 9),
        isa.addi(0, 0, 0),  # NOP
        isa.addi(2, 1, 1),
    ]
    load_program(dut, prog)
    await reset(dut)
    await run(dut, 30)

    assert reg(dut, 1) == 9
    assert reg(dut, 2) == 10


@cocotb.test()
async def fwd_load_to_next(dut):
    """Load result consumed by the very next instruction.

    With single-cycle SRAM and MEM-stage load_align computing combinationally,
    the dependent op in EX gets load_aligned forwarded from MEM->EX. No stall
    needed (this distinguishes the 5-stage from the old 3-stage which DID
    stall load-use)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # DMEM[0] = 0xCAFE_F00D
    # x1 = lw 0(x0)
    # x2 = x1 + 1
    prog = [
        isa.lw(1, 0, 0),
        isa.addi(2, 1, 1),
    ]
    load_program(dut, prog, dmem_init={0: 0xCAFE_F00D})
    await reset(dut)
    await run(dut, 30)

    assert reg(dut, 1) == 0xCAFEF00D, f"x1 = {reg(dut,1):#x}"
    # 0xCAFEF00D + 1 = 0xCAFEF00E (no carry)
    assert reg(dut, 2) == 0xCAFEF00E, f"x2 = {reg(dut,2):#x}"


@cocotb.test()
async def fwd_load_two_ahead(dut):
    """Load result consumed by an instruction two ahead — WB->EX of load value."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # DMEM[0] = 0x0000_002A (= 42)
    # x1 = lw 0(x0)
    # nop
    # x2 = x1 << 1
    prog = [
        isa.lw(1, 0, 0),
        isa.addi(0, 0, 0),
        isa.slli(2, 1, 1),
    ]
    load_program(dut, prog, dmem_init={0: 42})
    await reset(dut)
    await run(dut, 30)

    assert reg(dut, 1) == 42
    assert reg(dut, 2) == 84


@cocotb.test()
async def fwd_chain_three(dut):
    """Three-deep dependency chain — every consumer forwards from MEM."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # x1 = 1
    # x2 = x1 + 1   (=2)
    # x3 = x2 + x1  (=3)  -- consumer of BOTH x1 (WB->EX) AND x2 (MEM->EX)
    # x4 = x3 + x2  (=5)  -- consumer of BOTH x2 (WB->EX) AND x3 (MEM->EX)
    prog = [
        isa.addi(1, 0, 1),
        isa.addi(2, 1, 1),
        isa.add (3, 2, 1),
        isa.add (4, 3, 2),
    ]
    load_program(dut, prog)
    await reset(dut)
    await run(dut, 30)

    assert reg(dut, 1) == 1
    assert reg(dut, 2) == 2
    assert reg(dut, 3) == 3
    assert reg(dut, 4) == 5


@cocotb.test()
async def fwd_x0_never_forwards(dut):
    """Writes to x0 must never trigger forwarding — x0 reads are always 0."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # x0 = 99 (silently dropped — regfile won't write x0)
    # x1 = x0 + 7   (must read 0, not 99)
    prog = [
        isa.addi(0, 0, 99),
        isa.addi(1, 0, 7),
    ]
    load_program(dut, prog)
    await reset(dut)
    await run(dut, 30)

    assert reg(dut, 0) == 0
    assert reg(dut, 1) == 7


@cocotb.test()
async def fwd_store_data_post_forward(dut):
    """Store wdata must use the post-forwarded rs2 — producer in EX/MEM,
    store in EX, store consumes the producer's result via rs2 forwarding."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # x1 = 100
    # x2 = x1 + 5   -> 105
    # sw x2, 0(x0)  -> DMEM[0] = 105 (rs2=x2 must be forwarded)
    # x3 = lw 0(x0) -> 105
    prog = [
        isa.addi(1, 0, 100),
        isa.addi(2, 1, 5),
        isa.sw(2, 0, 0),
        isa.lw(3, 0, 0),
    ]
    load_program(dut, prog)
    await reset(dut)
    await run(dut, 40)

    assert reg(dut, 2) == 105
    assert reg(dut, 3) == 105, f"x3 = {reg(dut,3)}"
