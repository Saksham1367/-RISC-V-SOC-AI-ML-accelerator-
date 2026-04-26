"""
Minimal AXI4-Lite master-side helpers for cocotb tests.

Drives the s_axi_* slave interface of any AXI4-Lite slave with the standard
5-channel handshake. Synchronous, no out-of-order, no protocol checker.
"""

from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge


class AxiLiteMaster:
    def __init__(self, dut, prefix: str = "s_axi"):
        self.dut = dut
        self.p = prefix
        self.clk = dut.clk
        # init outputs (master side)
        self._set("awvalid", 0)
        self._set("wvalid", 0)
        self._set("bready", 0)
        self._set("arvalid", 0)
        self._set("rready", 0)
        self._set("awaddr", 0)
        self._set("wdata", 0)
        self._set("wstrb", 0)
        self._set("araddr", 0)

    def _sig(self, name):
        return getattr(self.dut, f"{self.p}_{name}")

    def _set(self, name, val):
        self._sig(name).value = val

    def _get(self, name):
        return int(self._sig(name).value)

    async def write(self, addr: int, data: int, strb: int = 0xF):
        # AW + W in parallel
        self._set("awaddr",  addr & 0xFFFFFFFF)
        self._set("awvalid", 1)
        self._set("wdata",   data & 0xFFFFFFFF)
        self._set("wstrb",   strb & 0xF)
        self._set("wvalid",  1)
        # wait for both ready
        aw_done, w_done = False, False
        while not (aw_done and w_done):
            await RisingEdge(self.clk)
            if not aw_done and self._get("awready"):
                aw_done = True
                self._set("awvalid", 0)
            if not w_done and self._get("wready"):
                w_done = True
                self._set("wvalid", 0)
        # accept B response
        self._set("bready", 1)
        while not self._get("bvalid"):
            await RisingEdge(self.clk)
        await RisingEdge(self.clk)
        self._set("bready", 0)

    async def read(self, addr: int) -> int:
        self._set("araddr",  addr & 0xFFFFFFFF)
        self._set("arvalid", 1)
        while not self._get("arready"):
            await RisingEdge(self.clk)
        await RisingEdge(self.clk)
        self._set("arvalid", 0)
        self._set("rready",  1)
        while not self._get("rvalid"):
            await RisingEdge(self.clk)
        data = self._get("rdata")
        await RisingEdge(self.clk)
        self._set("rready",  0)
        return data
