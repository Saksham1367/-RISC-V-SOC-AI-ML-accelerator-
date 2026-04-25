// =============================================================================
// regfile.sv — 32x32 RV32I register file
//   - 2 asynchronous read ports
//   - 1 synchronous write port
//   - x0 hardwired to zero (writes ignored)
//   - Internal forwarding: when reading and writing the same reg in same
//     cycle, the read returns the new value (write-before-read).
//     Helps the 3-stage pipeline avoid one extra forwarding path.
// =============================================================================
`default_nettype none

module regfile #(
  parameter int unsigned XLEN     = 32,
  parameter int unsigned NUM_REGS = 32
)(
  input  logic              clk,
  input  logic              rst_n,

  // read ports
  input  logic [4:0]        rs1_addr,
  input  logic [4:0]        rs2_addr,
  output logic [XLEN-1:0]   rs1_data,
  output logic [XLEN-1:0]   rs2_data,

  // write port
  input  logic              we,
  input  logic [4:0]        rd_addr,
  input  logic [XLEN-1:0]   rd_data
);

  logic [XLEN-1:0] regs [NUM_REGS-1:0];

  // synchronous write — x0 (addr 0) never updates
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NUM_REGS; i++) begin
        regs[i] <= '0;
      end
    end else if (we && (rd_addr != 5'd0)) begin
      regs[rd_addr] <= rd_data;
    end
  end

  // asynchronous read with internal write-before-read bypass.
  // x0 always reads as zero.
  always_comb begin
    if (rs1_addr == 5'd0)
      rs1_data = '0;
    else if (we && (rd_addr == rs1_addr) && (rd_addr != 5'd0))
      rs1_data = rd_data;
    else
      rs1_data = regs[rs1_addr];
  end

  always_comb begin
    if (rs2_addr == 5'd0)
      rs2_data = '0;
    else if (we && (rd_addr == rs2_addr) && (rd_addr != 5'd0))
      rs2_data = rd_data;
    else
      rs2_data = regs[rs2_addr];
  end

endmodule : regfile

`default_nettype wire
