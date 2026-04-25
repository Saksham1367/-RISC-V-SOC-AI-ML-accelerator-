// =============================================================================
// fetch.sv — IF stage: PC register, instruction memory address, branch redirect
//
// Synchronous instruction memory: PC drives imem_addr; instruction comes back
// next cycle. The pipeline treats the registered instruction as the ID stage's
// input.
//
// On a taken branch/jump (resolved in EX), pc_redirect is asserted with the
// new PC; we accept it next cycle and a 2-cycle bubble appears in IF/ID.
//
// Stall input (from hazard unit) freezes the PC for one cycle.
// =============================================================================
`default_nettype none

module fetch #(
  parameter logic [31:0] RESET_PC = 32'h0000_0000
)(
  input  logic         clk,
  input  logic         rst_n,

  // hazard / control
  input  logic         stall,         // freeze PC and IF/ID register
  input  logic         flush,         // squash current instruction (becomes NOP)
  input  logic         pc_redirect,
  input  logic [31:0]  pc_redirect_target,

  // instruction memory interface (synchronous, single-cycle)
  output logic [31:0]  imem_addr,
  output logic         imem_re,
  input  logic [31:0]  imem_rdata,

  // outputs to ID stage
  output logic [31:0]  if_pc,
  output logic [31:0]  if_instr,
  output logic         if_valid
);

  logic [31:0] pc_q, pc_next;
  logic [31:0] pc_at_fetch_q;        // PC corresponding to imem_rdata
  logic        valid_q;

  // -------- next-PC selection --------
  always_comb begin
    if (pc_redirect)        pc_next = pc_redirect_target;
    else if (stall)         pc_next = pc_q;
    else                    pc_next = pc_q + 32'd4;
  end

  // -------- PC register --------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_q          <= RESET_PC;
      pc_at_fetch_q <= RESET_PC;
      valid_q       <= 1'b0;
    end else begin
      pc_q          <= pc_next;
      pc_at_fetch_q <= pc_q;            // PC of the instr currently being read
      // Valid de-asserted on flush or first cycle after reset.
      valid_q       <= ~flush & ~pc_redirect;
    end
  end

  assign imem_addr = pc_q;
  assign imem_re   = 1'b1;

  // Instruction word forwarded to ID; on flush we replace with NOP (addi x0,x0,0).
  assign if_pc    = pc_at_fetch_q;
  assign if_instr = (flush || !valid_q) ? 32'h0000_0013 : imem_rdata;
  assign if_valid = valid_q;

endmodule : fetch

`default_nettype wire
