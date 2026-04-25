"""
Cocotb unit test for rtl/accelerator/pe.sv

Output-stationary PE: each cycle valid_in is high, acc += a_in * b_in
(signed). a_out/b_out are registered passes.
"""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


def s8(x: int) -> int:
    """Sign-extend 8-bit -> Python int."""
    x &= 0xFF
    return x - 0x100 if x & 0x80 else x


def s32(x: int) -> int:
    x &= 0xFFFFFFFF
    return x - 0x100000000 if x & 0x80000000 else x


async def reset(dut, cycles: int = 3):
    dut.rst_n.value     = 0
    dut.acc_clear.value = 0
    dut.a_in.value      = 0
    dut.b_in.value      = 0
    dut.valid_in.value  = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def reset_state(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    assert s32(int(dut.acc_out.value)) == 0
    assert int(dut.valid_out.value) == 0


@cocotb.test()
async def single_mac(dut):
    """One multiply-accumulate, then read acc."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    dut.a_in.value     = 7
    dut.b_in.value     = 3
    dut.valid_in.value = 1
    await RisingEdge(dut.clk)
    dut.valid_in.value = 0
    await RisingEdge(dut.clk)

    assert s32(int(dut.acc_out.value)) == 21


@cocotb.test()
async def signed_mac(dut):
    """Signed inputs across full INT8 range."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    pairs = [(-1, -1), (-128, -128), (127, -1), (-128, 127), (50, -50)]
    expected = 0
    for a, b in pairs:
        dut.a_in.value     = a & 0xFF
        dut.b_in.value     = b & 0xFF
        dut.valid_in.value = 1
        await RisingEdge(dut.clk)
        expected += a * b
    dut.valid_in.value = 0
    await RisingEdge(dut.clk)

    got = s32(int(dut.acc_out.value))
    assert got == expected, f"expected {expected} got {got}"


@cocotb.test()
async def acc_clear_works(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    # Pump a few products
    for _ in range(5):
        dut.a_in.value     = 10
        dut.b_in.value     = 10
        dut.valid_in.value = 1
        await RisingEdge(dut.clk)
    dut.valid_in.value = 0
    await RisingEdge(dut.clk)
    assert s32(int(dut.acc_out.value)) == 500

    # Clear
    dut.acc_clear.value = 1
    await RisingEdge(dut.clk)
    dut.acc_clear.value = 0
    await Timer(1, unit="ns")
    assert s32(int(dut.acc_out.value)) == 0


@cocotb.test()
async def pass_through_registered(dut):
    """a_out and b_out are registered — show 1-cycle delay."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    dut.a_in.value     = 5
    dut.b_in.value     = -3 & 0xFF
    dut.valid_in.value = 1
    await RisingEdge(dut.clk)
    # one cycle later: a_out should reflect previous a_in
    await Timer(1, unit="ns")
    assert s8(int(dut.a_out.value)) == 5
    assert s8(int(dut.b_out.value)) == -3
    assert int(dut.valid_out.value) == 1


@cocotb.test()
async def random_storm(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    random.seed(0xACC)
    expected = 0
    for _ in range(200):
        a = random.randint(-128, 127)
        b = random.randint(-128, 127)
        v = random.choice([0, 1])
        dut.a_in.value     = a & 0xFF
        dut.b_in.value     = b & 0xFF
        dut.valid_in.value = v
        await RisingEdge(dut.clk)
        if v:
            expected += a * b

    dut.valid_in.value = 0
    await RisingEdge(dut.clk)
    got = s32(int(dut.acc_out.value))
    assert got == expected, f"expected {expected} got {got}"
