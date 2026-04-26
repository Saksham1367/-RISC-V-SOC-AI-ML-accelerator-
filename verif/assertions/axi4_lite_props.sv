// =============================================================================
// axi4_lite_props.sv — Procedural protocol checker for AXI4-Lite slave ports.
//
// Hooked in via `bind` to any axi4_lite_slave instance. Implements the
// AXI4-Lite handshake invariants:
//
//   * VALID, once asserted, may not deassert until READY is observed.
//   * Address / data / wstrb on a channel is stable while VALID is high
//     and READY has not yet handshook.
//   * Slave responses are always OKAY (2'b00) for this design.
//
// Implementation note: Icarus Verilog's concurrent-assertion support is
// incomplete (no `$stable`, fragile `disable iff`), so the checks are
// expressed as procedural always_ff blocks. They run in any simulator and
// produce $error on violation.
// =============================================================================
`default_nettype none

module axi4_lite_props #(
  parameter int unsigned ADDR_W = 32,
  parameter int unsigned DATA_W = 32
)(
  input  logic                  clk,
  input  logic                  rst_n,

  input  logic                  awvalid,
  input  logic                  awready,
  input  logic [ADDR_W-1:0]     awaddr,

  input  logic                  wvalid,
  input  logic                  wready,
  input  logic [DATA_W-1:0]     wdata,
  input  logic [DATA_W/8-1:0]   wstrb,

  input  logic                  bvalid,
  input  logic                  bready,
  input  logic [1:0]            bresp,

  input  logic                  arvalid,
  input  logic                  arready,
  input  logic [ADDR_W-1:0]     araddr,

  input  logic                  rvalid,
  input  logic                  rready,
  input  logic [DATA_W-1:0]     rdata,
  input  logic [1:0]            rresp
);

  // ------------------------------------------------------------------
  // Snapshots of last-cycle values for stability/sticky checks
  // ------------------------------------------------------------------
  logic                  awvalid_q, wvalid_q, bvalid_q, arvalid_q, rvalid_q;
  logic                  awready_q, wready_q, bready_q, arready_q, rready_q;
  logic [ADDR_W-1:0]     awaddr_q,  araddr_q;
  logic [DATA_W-1:0]     wdata_q,   rdata_q;
  logic [DATA_W/8-1:0]   wstrb_q;

  always_ff @(posedge clk) begin
    awvalid_q <= awvalid;  awready_q <= awready;
    wvalid_q  <= wvalid;   wready_q  <= wready;
    bvalid_q  <= bvalid;   bready_q  <= bready;
    arvalid_q <= arvalid;  arready_q <= arready;
    rvalid_q  <= rvalid;   rready_q  <= rready;
    awaddr_q  <= awaddr;
    wdata_q   <= wdata;     wstrb_q <= wstrb;
    araddr_q  <= araddr;
    rdata_q   <= rdata;
  end

  // ------------------------------------------------------------------
  // Stickiness: once VALID is asserted it must remain asserted until READY
  // is observed. We detect violation by:
  //     last cycle had VALID=1, READY=0  AND  this cycle has VALID=0
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (awvalid_q && !awready_q && !awvalid) begin
        $error("%0t: AXI4-Lite AWVALID dropped before AWREADY", $time);
      end
      if (wvalid_q && !wready_q && !wvalid) begin
        $error("%0t: AXI4-Lite WVALID dropped before WREADY", $time);
      end
      if (bvalid_q && !bready_q && !bvalid) begin
        $error("%0t: AXI4-Lite BVALID dropped before BREADY", $time);
      end
      if (arvalid_q && !arready_q && !arvalid) begin
        $error("%0t: AXI4-Lite ARVALID dropped before ARREADY", $time);
      end
      if (rvalid_q && !rready_q && !rvalid) begin
        $error("%0t: AXI4-Lite RVALID dropped before RREADY", $time);
      end
    end
  end

  // ------------------------------------------------------------------
  // Payload stability while VALID held without READY
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (awvalid_q && !awready_q && awvalid && (awaddr !== awaddr_q)) begin
        $error("%0t: AXI4-Lite AWADDR changed while AWVALID held without AWREADY", $time);
      end
      if (wvalid_q && !wready_q && wvalid && (wdata !== wdata_q)) begin
        $error("%0t: AXI4-Lite WDATA changed while WVALID held without WREADY", $time);
      end
      if (wvalid_q && !wready_q && wvalid && (wstrb !== wstrb_q)) begin
        $error("%0t: AXI4-Lite WSTRB changed while WVALID held without WREADY", $time);
      end
      if (arvalid_q && !arready_q && arvalid && (araddr !== araddr_q)) begin
        $error("%0t: AXI4-Lite ARADDR changed while ARVALID held without ARREADY", $time);
      end
    end
  end

  // ------------------------------------------------------------------
  // Response code: only OKAY (2'b00) is expected for this design
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (bvalid && bresp !== 2'b00)
        $error("%0t: AXI4-Lite BRESP non-OKAY: %02b", $time, bresp);
      if (rvalid && rresp !== 2'b00)
        $error("%0t: AXI4-Lite RRESP non-OKAY: %02b", $time, rresp);
    end
  end

endmodule : axi4_lite_props

`default_nettype wire
