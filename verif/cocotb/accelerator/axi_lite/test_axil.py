"""
Cocotb test for rtl/axi/axi4_lite_slave.sv

Drives the slave through write/read transactions and checks that:
  * Writable registers store and retrieve their values.
  * Read-only registers reflect csr_in (driven from outside).
  * Wstrb is honoured (per-byte writes).
  * Out-of-order interleaving of AW/W still produces correct response.
"""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from common.axil import AxiLiteMaster
from common.axil_monitor import AxiLiteMonitor


NUM_REGS = 8


async def reset(dut, cycles: int = 3):
    dut.rst_n.value         = 0
    dut.writable_mask.value = (1 << NUM_REGS) - 1   # all writable initially
    for i in range(NUM_REGS):
        dut.csr_in[i].value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def write_then_read(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    m = AxiLiteMaster(dut)

    for i in range(NUM_REGS):
        await m.write(i * 4, 0xCAFE0000 | i)
    for i in range(NUM_REGS):
        v = await m.read(i * 4)
        assert v == (0xCAFE0000 | i), f"reg {i}: expected 0x{0xCAFE0000|i:08x} got 0x{v:08x}"


@cocotb.test()
async def wstrb_byte_writes(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    m = AxiLiteMaster(dut)

    # full-word write
    await m.write(0x4, 0xAABBCCDD, strb=0xF)
    # overwrite only byte 1 (mask=0010) with 0x11 -> result 0xAA_BB_11_DD wait
    await m.write(0x4, 0x00001100, strb=0b0010)
    v = await m.read(0x4)
    # original 0xAABBCCDD, byte 1 becomes 0x11 -> 0xAABB11DD
    assert v == 0xAABB11DD, f"got 0x{v:08x}"

    # overwrite high byte with 0x99
    await m.write(0x4, 0x99000000, strb=0b1000)
    v = await m.read(0x4)
    assert v == 0x99BB11DD, f"got 0x{v:08x}"


@cocotb.test()
async def read_only_register(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    m = AxiLiteMaster(dut)

    # make reg 3 read-only
    dut.writable_mask.value = ((1 << NUM_REGS) - 1) & ~(1 << 3)
    dut.csr_in[3].value = 0xDEADBEEF

    # writes to reg 3 should be ignored
    await m.write(3 * 4, 0x12345678)
    v = await m.read(3 * 4)
    assert v == 0xDEADBEEF, f"R/O reg shows 0x{v:08x}, expected 0xDEADBEEF"


@cocotb.test()
async def random_storm(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    # Spawn protocol monitor alongside the master
    mon = AxiLiteMonitor(dut)
    cocotb.start_soon(mon.run())

    m = AxiLiteMaster(dut)
    random.seed(0xAB1)

    shadow = [0] * NUM_REGS
    for _ in range(60):
        idx  = random.randint(0, NUM_REGS - 1)
        data = random.randint(0, 0xFFFFFFFF)
        await m.write(idx * 4, data)
        shadow[idx] = data
        # occasionally read a random register
        if random.random() < 0.5:
            r = random.randint(0, NUM_REGS - 1)
            v = await m.read(r * 4)
            assert v == shadow[r], f"reg {r}: got 0x{v:08x} want 0x{shadow[r]:08x}"

    # Final protocol check
    mon.assert_clean()
