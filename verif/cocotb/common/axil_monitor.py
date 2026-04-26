"""
AXI4-Lite protocol monitor for cocotb.

Spawned as a background coroutine alongside an active test. Watches all 5
channels on every clock edge and counts protocol violations:

  * VALID dropped before READY (handshake stickiness)
  * Address / data / wstrb changed while VALID held without READY
  * Non-OKAY response on B / R

Usage:
    mon = AxiLiteMonitor(dut)
    cocotb.start_soon(mon.run())
    ...
    mon.assert_clean()
"""

from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge


class AxiLiteMonitor:
    def __init__(self, dut, prefix: str = "s_axi"):
        self.dut = dut
        self.p = prefix
        self.errors: list[str] = []

    def _g(self, name: str) -> int:
        return int(getattr(self.dut, f"{self.p}_{name}").value)

    def _gx(self, name: str) -> int:
        # for vectors that may be larger than int — treat as int
        return int(getattr(self.dut, f"{self.p}_{name}").value)

    def err(self, msg: str):
        self.errors.append(msg)

    async def run(self):
        clk = self.dut.clk
        prev = {}

        await RisingEdge(clk)  # let reset settle one cycle
        prev = {
            "awvalid": self._g("awvalid"), "awready": self._g("awready"),
            "wvalid":  self._g("wvalid"),  "wready":  self._g("wready"),
            "bvalid":  self._g("bvalid"),  "bready":  self._g("bready"),
            "arvalid": self._g("arvalid"), "arready": self._g("arready"),
            "rvalid":  self._g("rvalid"),  "rready":  self._g("rready"),
            "awaddr":  self._gx("awaddr"),
            "wdata":   self._gx("wdata"),  "wstrb":   self._g("wstrb"),
            "araddr":  self._gx("araddr"),
        }

        cycle = 0
        while True:
            await RisingEdge(clk)
            cycle += 1
            if int(self.dut.rst_n.value) == 0:
                continue

            cur = {
                "awvalid": self._g("awvalid"), "awready": self._g("awready"),
                "wvalid":  self._g("wvalid"),  "wready":  self._g("wready"),
                "bvalid":  self._g("bvalid"),  "bready":  self._g("bready"),
                "arvalid": self._g("arvalid"), "arready": self._g("arready"),
                "rvalid":  self._g("rvalid"),  "rready":  self._g("rready"),
                "awaddr":  self._gx("awaddr"),
                "wdata":   self._gx("wdata"),  "wstrb":   self._g("wstrb"),
                "araddr":  self._gx("araddr"),
            }

            # Stickiness: VALID dropped before READY
            for ch in ("aw", "w", "b", "ar", "r"):
                v_prev, r_prev = prev[f"{ch}valid"], prev[f"{ch}ready"]
                v_now           = cur[f"{ch}valid"]
                if v_prev and not r_prev and not v_now:
                    self.err(f"cycle {cycle}: {ch.upper()}VALID dropped before {ch.upper()}READY")

            # Stability of payload while VALID held without READY
            if prev["awvalid"] and not prev["awready"] and cur["awvalid"]:
                if cur["awaddr"] != prev["awaddr"]:
                    self.err(f"cycle {cycle}: AWADDR changed while VALID held without READY")
            if prev["wvalid"] and not prev["wready"] and cur["wvalid"]:
                if cur["wdata"] != prev["wdata"]:
                    self.err(f"cycle {cycle}: WDATA changed while VALID held without READY")
                if cur["wstrb"] != prev["wstrb"]:
                    self.err(f"cycle {cycle}: WSTRB changed while VALID held without READY")
            if prev["arvalid"] and not prev["arready"] and cur["arvalid"]:
                if cur["araddr"] != prev["araddr"]:
                    self.err(f"cycle {cycle}: ARADDR changed while VALID held without READY")

            # Response codes
            if cur["bvalid"] and int(self.dut.s_axi_bresp.value) != 0:
                self.err(f"cycle {cycle}: BRESP non-OKAY")
            if cur["rvalid"] and int(self.dut.s_axi_rresp.value) != 0:
                self.err(f"cycle {cycle}: RRESP non-OKAY")

            prev = cur

    def assert_clean(self):
        if self.errors:
            head = "\n  ".join(self.errors[:5])
            raise AssertionError(
                f"{len(self.errors)} AXI4-Lite protocol violations. First 5:\n  {head}"
            )
