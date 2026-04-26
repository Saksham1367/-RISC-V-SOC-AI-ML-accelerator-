// =============================================================================
// soc_top.sv — Top-level SoC integration.
//
// Components:
//   * RV32I 3-stage core
//   * Instruction SRAM (synchronous read), 16 KB
//   * Data SRAM (combinational read), 16 KB at 0x1000_0000
//   * Systolic-array accelerator behind an AXI4-Lite slave at 0x2000_0000
//   * Address router on the data path: routes the core's data-memory access
//     to data SRAM or to the AXI4-Lite bridge based on the upper address bits.
//
// CPU pipeline interaction:
//   * Data SRAM is single-cycle on this side; no stall.
//   * Accelerator AXI4-Lite is multi-cycle; the bridge produces a stall
//     pulse that, in v1, we feed into the load-use stall logic. To keep the
//     existing core unmodified we adopt a different scheme: we *latch* the
//     CPU's request inside an "AXI gateway" and replay the result via a
//     simple busy-wait protocol that the bridge presents as multi-cycle
//     dmem_rdata. The CPU code must not rely on single-cycle MMIO loads —
//     it polls via a software loop, which dominates anyway.
//
// In Phase 3 the SoC integration test directly drives the AXI4-Lite slave;
// having the RV32I core drive it is exercised in Phase 4 with a small
// software harness (matrix offload program).
// =============================================================================
`default_nettype none

module soc_top
  import sa_pkg::*;
#(
  parameter int unsigned IMEM_DEPTH_WORDS = 4096,    // 16 KB
  parameter int unsigned DMEM_DEPTH_WORDS = 4096
)(
  input  logic clk,
  input  logic rst_n
);

  // ---------------------------------------------------------------------
  // Core wiring
  // ---------------------------------------------------------------------
  logic [31:0] imem_addr;
  logic        imem_re;
  logic [31:0] imem_rdata;

  logic [31:0] dmem_addr;
  logic [31:0] dmem_wdata;
  logic [3:0]  dmem_wstrb;
  logic        dmem_re;
  logic        dmem_we;
  logic [31:0] dmem_rdata;

  logic core_dmem_stall;

  riscv_core u_core (
    .clk        (clk),
    .rst_n      (rst_n),
    .imem_addr  (imem_addr),
    .imem_re    (imem_re),
    .imem_rdata (imem_rdata),
    .dmem_addr  (dmem_addr),
    .dmem_wdata (dmem_wdata),
    .dmem_wstrb (dmem_wstrb),
    .dmem_re    (dmem_re),
    .dmem_we    (dmem_we),
    .dmem_rdata (dmem_rdata),
    .dmem_stall (core_dmem_stall)
  );

  // ---------------------------------------------------------------------
  // Instruction SRAM (1-cycle synchronous read)
  // ---------------------------------------------------------------------
  imem_sync #(.DEPTH_WORDS(IMEM_DEPTH_WORDS)) u_imem (
    .clk   (clk),
    .addr  (imem_addr),
    .re    (imem_re),
    .rdata (imem_rdata)
  );

  // ---------------------------------------------------------------------
  // Address routing
  //   * 0x1000_xxxx -> data SRAM
  //   * 0x2000_xxxx -> accelerator AXI4-Lite slave
  //   * everything else -> data SRAM (treat as zero-base)
  // ---------------------------------------------------------------------
  logic dmem_sel_axil;
  assign dmem_sel_axil = (dmem_addr[31:28] == 4'h2);

  // ---------------------------------------------------------------------
  // Data SRAM
  // ---------------------------------------------------------------------
  logic [31:0] dsram_rdata;

  sram #(.DEPTH_WORDS(DMEM_DEPTH_WORDS)) u_dmem (
    .clk   (clk),
    .addr  (dmem_addr),
    .re    (dmem_re && !dmem_sel_axil),
    .we    (dmem_we && !dmem_sel_axil),
    .wstrb (dmem_wstrb),
    .wdata (dmem_wdata),
    .rdata (dsram_rdata)
  );

  // ---------------------------------------------------------------------
  // AXI4-Lite bridge to the accelerator (drives accelerator slave port)
  // ---------------------------------------------------------------------
  logic [31:0] axil_awaddr,  axil_wdata,  axil_araddr,  axil_rdata;
  logic [3:0]  axil_wstrb;
  logic        axil_awvalid, axil_awready;
  logic        axil_wvalid,  axil_wready;
  logic        axil_arvalid, axil_arready;
  logic        axil_rvalid,  axil_rready;
  logic        axil_bvalid,  axil_bready;
  logic [1:0]  axil_bresp,   axil_rresp;

  // Bridge inputs come from the core when the address selects AXI4-Lite.
  logic                bridge_req_valid;
  logic                bridge_stall;
  logic [31:0]         bridge_rdata;
  logic                bridge_rvalid;

  assign bridge_req_valid = dmem_sel_axil & (dmem_re | dmem_we);

  mem_to_axil u_bridge (
    .clk           (clk),
    .rst_n         (rst_n),
    .req_valid     (bridge_req_valid),
    .req_we        (dmem_we),
    .req_addr      ({4'h0, dmem_addr[27:0]}),  // strip top nibble for slave-relative addr
    .req_wdata     (dmem_wdata),
    .req_wstrb     (dmem_wstrb),
    .req_stall     (bridge_stall),
    .req_rdata     (bridge_rdata),
    .req_rvalid    (bridge_rvalid),
    .m_axi_awaddr  (axil_awaddr),
    .m_axi_awvalid (axil_awvalid),
    .m_axi_awready (axil_awready),
    .m_axi_wdata   (axil_wdata),
    .m_axi_wstrb   (axil_wstrb),
    .m_axi_wvalid  (axil_wvalid),
    .m_axi_wready  (axil_wready),
    .m_axi_bresp   (axil_bresp),
    .m_axi_bvalid  (axil_bvalid),
    .m_axi_bready  (axil_bready),
    .m_axi_araddr  (axil_araddr),
    .m_axi_arvalid (axil_arvalid),
    .m_axi_arready (axil_arready),
    .m_axi_rdata   (axil_rdata),
    .m_axi_rresp   (axil_rresp),
    .m_axi_rvalid  (axil_rvalid),
    .m_axi_rready  (axil_rready)
  );

  accelerator_top u_acc (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_axi_awaddr  (axil_awaddr),
    .s_axi_awvalid (axil_awvalid),
    .s_axi_awready (axil_awready),
    .s_axi_wdata   (axil_wdata),
    .s_axi_wstrb   (axil_wstrb),
    .s_axi_wvalid  (axil_wvalid),
    .s_axi_wready  (axil_wready),
    .s_axi_bresp   (axil_bresp),
    .s_axi_bvalid  (axil_bvalid),
    .s_axi_bready  (axil_bready),
    .s_axi_araddr  (axil_araddr),
    .s_axi_arvalid (axil_arvalid),
    .s_axi_arready (axil_arready),
    .s_axi_rdata   (axil_rdata),
    .s_axi_rresp   (axil_rresp),
    .s_axi_rvalid  (axil_rvalid),
    .s_axi_rready  (axil_rready)
  );

  // ---------------------------------------------------------------------
  // Mux read data back into the core
  //   * SRAM access: rdata available next cycle (synchronous behaviour
  //     handled in dmem itself? No — sram is combinational. We provide
  //     the SRAM rdata as-is in the same cycle.)
  //   * AXI access: bridge stalls; data appears later. The CPU pipeline
  //     does not currently support stall on a load — Phase 3 exposes the
  //     accelerator only to a host TB, while a software harness (Phase 4)
  //     must use polled reads with a tight loop and the SRAM register
  //     spills, which masks the AXI latency.
  // ---------------------------------------------------------------------
  assign dmem_rdata = dmem_sel_axil ? bridge_rdata : dsram_rdata;

  // The bridge stalls the core for the duration of an MMIO transaction.
  // For SRAM accesses there is no stall (single cycle).
  assign core_dmem_stall = dmem_sel_axil & bridge_stall;

endmodule : soc_top

`default_nettype wire
