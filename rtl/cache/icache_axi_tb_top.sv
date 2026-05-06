// =============================================================================
// icache_axi_tb_top.sv — Phase-2a testbench harness for the I-cache + AXI4
// slave loop. Wraps:
//   * u_icache (DUT)
//   * u_axi_slave_sram (backing memory, 16 KiB)
//
// The cocotb test pokes initial program data into u_axi_slave_sram.u_sram.mem,
// then drives cpu_addr/cpu_re and verifies cpu_rdata + cpu_stall behavior on
// hits, misses, and burst refills.
// =============================================================================
`default_nettype none

module icache_axi_tb_top
  import cache_pkg::*;
#(
  parameter int unsigned MEM_DEPTH_WORDS = 4096,
  parameter int unsigned ID_W = 4
)(
  input  logic clk,
  input  logic rst_n,

  // CPU side, exposed to cocotb
  input  logic [31:0] cpu_addr,
  input  logic        cpu_re,
  output logic [31:0] cpu_rdata,
  output logic        cpu_stall
);

  // ----- AXI4-Full read channel between cache and slave -----
  logic [ID_W-1:0] arid;
  logic [31:0]     araddr;
  logic [7:0]      arlen;
  logic [2:0]      arsize;
  logic [1:0]      arburst;
  logic            arvalid, arready;

  logic [ID_W-1:0] rid;
  logic [31:0]     rdata;
  logic [1:0]      rresp;
  logic            rlast;
  logic            rvalid, rready;

  // I-cache DUT
  icache #(.ID_W(ID_W)) u_icache (
    .clk            (clk),
    .rst_n          (rst_n),
    .cpu_addr       (cpu_addr),
    .cpu_re         (cpu_re),
    .cpu_rdata      (cpu_rdata),
    .cpu_stall      (cpu_stall),
    .m_axi_arid     (arid),
    .m_axi_araddr   (araddr),
    .m_axi_arlen    (arlen),
    .m_axi_arsize   (arsize),
    .m_axi_arburst  (arburst),
    .m_axi_arvalid  (arvalid),
    .m_axi_arready  (arready),
    .m_axi_rid      (rid),
    .m_axi_rdata    (rdata),
    .m_axi_rresp    (rresp),
    .m_axi_rlast    (rlast),
    .m_axi_rvalid   (rvalid),
    .m_axi_rready   (rready)
  );

  // AXI4-Full slave wrapping SRAM. Drives unused write ports with quiet defaults.
  axi4_full_slave_sram #(
    .ADDR_W      (32),
    .DATA_W      (32),
    .ID_W        (ID_W),
    .DEPTH_WORDS (MEM_DEPTH_WORDS)
  ) u_slave (
    .clk            (clk),
    .rst_n          (rst_n),
    .s_axi_arid     (arid),
    .s_axi_araddr   (araddr),
    .s_axi_arlen    (arlen),
    .s_axi_arsize   (arsize),
    .s_axi_arburst  (arburst),
    .s_axi_arvalid  (arvalid),
    .s_axi_arready  (arready),
    .s_axi_rid      (rid),
    .s_axi_rdata    (rdata),
    .s_axi_rresp    (rresp),
    .s_axi_rlast    (rlast),
    .s_axi_rvalid   (rvalid),
    .s_axi_rready   (rready),
    // Write ports unused
    .s_axi_awid     ('0),
    .s_axi_awaddr   ('0),
    .s_axi_awlen    ('0),
    .s_axi_awsize   ('0),
    .s_axi_awburst  ('0),
    .s_axi_awvalid  (1'b0),
    .s_axi_awready  (),
    .s_axi_wdata    ('0),
    .s_axi_wstrb    ('0),
    .s_axi_wlast    (1'b0),
    .s_axi_wvalid   (1'b0),
    .s_axi_wready   (),
    .s_axi_bid      (),
    .s_axi_bresp    (),
    .s_axi_bvalid   (),
    .s_axi_bready   (1'b0)
  );

endmodule : icache_axi_tb_top

`default_nettype wire
