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
// Stall input (from hazard unit) freezes the PC for one cycle. While stalled,
// the IMEM continues to return data for the held PC (which is the address of
// the *next* instruction, not the one we're holding for ID), so we capture
// the in-flight instruction in `held_instr_q` and present that to ID until
// the stall releases.
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
  logic [31:0] pc_at_fetch_q;
  logic        valid_q;
  logic [31:0] held_instr_q;
  logic        held_valid_q;

  // -------- next-PC selection --------
  always_comb begin
    if (pc_redirect)        pc_next = pc_redirect_target;
    else if (stall)         pc_next = pc_q;
    else                    pc_next = pc_q + 32'd4;
  end

  // -------- PC + bookkeeping registers --------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_q          <= RESET_PC;
      pc_at_fetch_q <= RESET_PC;
      valid_q       <= 1'b0;
      held_instr_q  <= 32'h0000_0013;  // NOP
      held_valid_q  <= 1'b0;
    end else begin
      pc_q <= pc_next;

      if (pc_redirect) begin
        // Redirect: in-flight imem fetch is for the wrong PC; invalidate it
        // and drop any held instruction.
        pc_at_fetch_q <= pc_redirect_target;
        valid_q       <= 1'b0;
        held_valid_q  <= 1'b0;
      end else if (!stall) begin
        // Normal advance: PC moves forward; align pc_at_fetch_q with the
        // address whose data lives on imem_rdata next cycle.
        pc_at_fetch_q <= pc_q;
        valid_q       <= 1'b1;
        held_valid_q  <= 1'b0;
      end else begin
        // Stalled: capture imem_rdata once so we don't lose it as the IMEM
        // continues to return data for the (frozen) next-PC.
        if (!held_valid_q) begin
          held_instr_q <= imem_rdata;
          held_valid_q <= 1'b1;
        end
        // pc_at_fetch_q and valid_q hold their current values.
      end
    end
  end

  assign imem_addr = pc_q;
  assign imem_re   = 1'b1;

  // Instruction word forwarded to ID
  assign if_pc    = pc_at_fetch_q;
  assign if_instr = (flush || !valid_q) ? 32'h0000_0013
                                        : (held_valid_q ? held_instr_q : imem_rdata);
  assign if_valid = valid_q;

endmodule : fetch

`default_nettype wire
