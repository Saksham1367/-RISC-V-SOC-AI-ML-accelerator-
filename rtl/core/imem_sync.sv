// =============================================================================
// imem_sync.sv — Synchronous-read instruction memory wrapper.
//
// The core's fetch logic assumes a 1-cycle read latency on imem: PC presented
// at cycle N is returned as imem_rdata at cycle N+1. This wrapper registers
// the SRAM combinational read to satisfy that contract.
// =============================================================================
`default_nettype none

module imem_sync #(
  parameter int unsigned DEPTH_WORDS = 4096,
  parameter string       INIT_FILE   = ""
)(
  input  logic         clk,
  input  logic [31:0]  addr,
  input  logic         re,
  output logic [31:0]  rdata
);

  logic [31:0] sram_rdata;

  sram #(
    .DEPTH_WORDS (DEPTH_WORDS),
    .INIT_FILE   (INIT_FILE)
  ) u_sram (
    .clk    (clk),
    .addr   (addr),
    .re     (re),
    .we     (1'b0),
    .wstrb  (4'h0),
    .wdata  (32'h0),
    .rdata  (sram_rdata)
  );

  // Register the read to provide 1-cycle latency to the core.
  always_ff @(posedge clk) begin
    rdata <= sram_rdata;
  end

endmodule : imem_sync

`default_nettype wire
