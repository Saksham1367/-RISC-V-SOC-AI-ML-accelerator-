// =============================================================================
// execute.sv — EX stage
// Combinational ALU + branch resolution + memory address generation.
// Drives data memory request (load/store) and the writeback value.
//
// All latching is done by ID/EX pipeline registers in the core top —
// this module is pure combinational.
// =============================================================================
`default_nettype none

import riscv_pkg::*;
module execute(
  // pipelined ID/EX inputs
  input  ctrl_t        ctrl,
  input  logic [31:0]  pc,         // PC of this instruction
  input  logic [31:0]  rs1_data,
  input  logic [31:0]  rs2_data,

  // ALU + branch outputs
  output logic [31:0]  alu_result,
  output logic         branch_taken,
  output logic [31:0]  branch_target,

  // data memory request (driven combinationally; consumer registers as needed)
  output logic [31:0]  dmem_addr,
  output logic [31:0]  dmem_wdata,
  output logic [3:0]   dmem_wstrb,
  output logic         dmem_re,
  output logic         dmem_we
);

  // -------- ALU operand selection --------
  logic [31:0] op_a, op_b;
  assign op_a = (ctrl.src_a_sel == SRC_A_PC)  ? pc       : rs1_data;
  assign op_b = (ctrl.src_b_sel == SRC_B_IMM) ? ctrl.imm : rs2_data;

  // -------- ALU --------
  logic alu_zero;
  alu u_alu (
    .a    (op_a),
    .b    (op_b),
    .op   (ctrl.alu_op),
    .y    (alu_result),
    .zero (alu_zero)
  );

  // -------- Branch evaluation (always uses raw rs1/rs2) --------
  logic br_taken;
  branch_unit u_br (
    .br_type (ctrl.br_type),
    .a       (rs1_data),
    .b       (rs2_data),
    .taken   (br_taken)
  );

  // Branch target: JALR uses (rs1 + imm) & ~1; everything else uses PC + imm.
  logic [31:0] br_tgt;
  always_comb begin
    if (ctrl.is_jalr)
      br_tgt = (rs1_data + ctrl.imm) & ~32'h1;
    else
      br_tgt = pc + ctrl.imm;
  end

  assign branch_taken  = br_taken;
  assign branch_target = br_tgt;

  // -------- Memory request --------
  // Address = ALU result (which is rs1 + imm for loads/stores).
  assign dmem_addr = alu_result;
  assign dmem_re   = ctrl.mem_re;
  assign dmem_we   = ctrl.mem_we;

  // Build write strobe + aligned wdata for SB/SH/SW
  logic [1:0] byte_off;
  assign byte_off = alu_result[1:0];

  always_comb begin
    dmem_wdata = 32'h0;
    dmem_wstrb = 4'h0;
    unique case (ctrl.mem_size)
      MEM_B: begin
        dmem_wdata = {4{rs2_data[7:0]}};
        dmem_wstrb = 4'b0001 << byte_off;
      end
      MEM_H: begin
        dmem_wdata = {2{rs2_data[15:0]}};
        dmem_wstrb = 4'b0011 << byte_off;
      end
      MEM_W: begin
        dmem_wdata = rs2_data;
        dmem_wstrb = 4'b1111;
      end
      default: begin
        dmem_wdata = rs2_data;
        dmem_wstrb = 4'b1111;
      end
    endcase
  end

endmodule : execute

`default_nettype wire
