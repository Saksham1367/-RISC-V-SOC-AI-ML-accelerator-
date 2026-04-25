// =============================================================================
// sram.sv — Single-port synchronous SRAM model with byte-write strobe.
//
// Behaviour:
//   * Word-addressed externally via a 32-bit byte address (low 2 bits ignored
//     for word access; wstrb selects which bytes to update).
//   * Synchronous write on posedge clk.
//   * Combinational (asynchronous) read — addressing the array directly.
//
// Suitable as a behavioural model for both instruction and data memories in
// simulation. For FPGA mapping, swap to a synchronous-read variant or rely
// on inference of block RAM.
// =============================================================================
`default_nettype none

module sram #(
  parameter int unsigned DEPTH_WORDS = 4096,         // 16 KB
  parameter int unsigned ADDR_W      = $clog2(DEPTH_WORDS),
  parameter string       INIT_FILE   = ""            // optional $readmemh image
)(
  input  logic         clk,
  input  logic [31:0]  addr,
  input  logic         re,
  input  logic         we,
  input  logic [3:0]   wstrb,
  input  logic [31:0]  wdata,
  output logic [31:0]  rdata
);

  logic [31:0] mem [0:DEPTH_WORDS-1];

  // Word index from byte address
  logic [ADDR_W-1:0] word_idx;
  assign word_idx = addr[ADDR_W+1:2];

  initial begin
    for (int i = 0; i < DEPTH_WORDS; i++) begin
      mem[i] = 32'h0;
    end
    if (INIT_FILE != "") begin
      $readmemh(INIT_FILE, mem);
    end
  end

  // Synchronous byte-strobed write
  always_ff @(posedge clk) begin
    if (we) begin
      if (wstrb[0]) mem[word_idx][7:0]   <= wdata[7:0];
      if (wstrb[1]) mem[word_idx][15:8]  <= wdata[15:8];
      if (wstrb[2]) mem[word_idx][23:16] <= wdata[23:16];
      if (wstrb[3]) mem[word_idx][31:24] <= wdata[31:24];
    end
  end

  // Combinational read
  assign rdata = re ? mem[word_idx] : 32'h0;

endmodule : sram

`default_nettype wire
