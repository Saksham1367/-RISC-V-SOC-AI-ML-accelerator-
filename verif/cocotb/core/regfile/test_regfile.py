"""
Cocotb unit test for rtl/core/regfile.sv

Verifies:
  * Synchronous write, asynchronous read.
  * x0 always reads zero, never updates.
  * Internal write-before-read bypass: same-cycle write+read returns new value.
  * Two read ports independent.
"""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


async def reset(dut):
    dut.rst_n.value    = 0
    dut.we.value       = 0
    dut.rd_addr.value  = 0
    dut.rd_data.value  = 0
    dut.rs1_addr.value = 0
    dut.rs2_addr.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def write(dut, addr: int, data: int):
    """Pulse a synchronous write (one clock)."""
    dut.we.value      = 1
    dut.rd_addr.value = addr
    dut.rd_data.value = data
    await RisingEdge(dut.clk)
    dut.we.value = 0


def read(dut, port: str, addr: int) -> int:
    """Drive a read addr and return the combinational data after settle."""
    if port == "rs1":
        dut.rs1_addr.value = addr
    else:
        dut.rs2_addr.value = addr


@cocotb.test()
async def x0_is_zero(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    # write garbage to x0 — must not stick
    await write(dut, 0, 0xDEADBEEF)
    dut.rs1_addr.value = 0
    await Timer(1, units="ns")
    assert int(dut.rs1_data.value) == 0, "x0 read non-zero after write"


@cocotb.test()
async def write_then_read(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    for addr in [1, 5, 17, 31]:
        val = (addr * 0x1010101) & 0xFFFFFFFF
        await write(dut, addr, val)
        # one clock later, read
        await RisingEdge(dut.clk)
        dut.rs1_addr.value = addr
        await Timer(1, units="ns")
        got = int(dut.rs1_data.value)
        assert got == val, f"x{addr}: expected 0x{val:08x} got 0x{got:08x}"


@cocotb.test()
async def write_before_read_bypass(dut):
    """Same cycle: write x7=val and read rs1_addr=7 → see new val (bypass)."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    dut.we.value       = 1
    dut.rd_addr.value  = 7
    dut.rd_data.value  = 0xCAFEBABE
    dut.rs1_addr.value = 7
    await Timer(1, units="ns")
    got = int(dut.rs1_data.value)
    assert got == 0xCAFEBABE, f"bypass failed: got 0x{got:08x}"

    await RisingEdge(dut.clk)
    dut.we.value = 0


@cocotb.test()
async def two_ports_independent(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    # populate x1..x10 with i*0x100
    for i in range(1, 11):
        await write(dut, i, i * 0x100)

    await RisingEdge(dut.clk)

    # read pairs
    for a, b in [(1, 2), (3, 7), (10, 5), (4, 9)]:
        dut.rs1_addr.value = a
        dut.rs2_addr.value = b
        await Timer(1, units="ns")
        v1 = int(dut.rs1_data.value)
        v2 = int(dut.rs2_data.value)
        assert v1 == a * 0x100, f"rs1 read x{a}: got 0x{v1:08x}"
        assert v2 == b * 0x100, f"rs2 read x{b}: got 0x{v2:08x}"


@cocotb.test()
async def random_storm(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    random.seed(0xBEEF)
    shadow = [0] * 32  # x0 stays 0

    N = 500
    for _ in range(N):
        if random.random() < 0.6:
            addr = random.randint(0, 31)
            data = random.randint(0, 0xFFFFFFFF)
            await write(dut, addr, data)
            if addr != 0:
                shadow[addr] = data
        else:
            await RisingEdge(dut.clk)

        # check a random port read
        a = random.randint(0, 31)
        dut.rs1_addr.value = a
        await Timer(1, units="ns")
        got = int(dut.rs1_data.value)
        assert got == shadow[a], f"x{a}: expected 0x{shadow[a]:08x} got 0x{got:08x}"
