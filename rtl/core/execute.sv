// =============================================================================
// execute.sv — EX stage (5-stage pipeline)
//
// Pure-combinational outputs for the ALU + branch path; the iterative divider
// (div32) lives inside this module because divide stalls are an EX-stage
// concern. Memory address generation and the dmem drive moved to the MEM
// stage in riscv_core.sv.
//
// Inputs (from ID/EX register, after operand forwarding):
//   ctrl, pc, rs1_data, rs2_data
// Outputs:
//   alu_result    — for ALU/MUL/DIV ops; for L/S, this IS the address.
//   branch_taken  — combinational, drives flush_if/pc_redirect in core
//   branch_target — JALR uses (rs1 + imm) & ~1, else PC + imm
//   div_busy      — high while divide is iterating; core stalls IF/ID/EX.
//   div_ack       — pulsed by core when EX/MEM register captures the divide
//                   result, freeing div32 to accept the next divide.
// =============================================================================
`default_nettype none

module execute
  import riscv_pkg::*;
(
  input  logic         clk,
  input  logic         rst_n,

  // pipelined ID/EX inputs (rs1/rs2 already forwarded by core)
  input  ctrl_t        ctrl,
  input  logic [31:0]  pc,
  input  logic [31:0]  rs1_data,
  input  logic [31:0]  rs2_data,
  input  logic         valid,        // 0 = bubble; suppresses div_start

  // EX advance signal: pulses when the EX/MEM register will capture this
  // cycle's outputs. Used to hand the divide result off to MEM stage.
  input  logic         ex_advance,

  // ALU + branch outputs
  output logic [31:0]  alu_result,
  output logic         branch_taken,
  output logic [31:0]  branch_target,

  // divider stall signal back to hazard unit
  output logic         div_busy
);

  // -------- ALU operand selection --------
  logic [31:0] op_a, op_b;
  assign op_a = (ctrl.src_a_sel == SRC_A_PC)  ? pc       : rs1_data;
  assign op_b = (ctrl.src_b_sel == SRC_B_IMM) ? ctrl.imm : rs2_data;

  // -------- ALU (covers RV32I + RV32M MUL family) --------
  logic [31:0] alu_y;
  logic        alu_zero;
  alu u_alu (
    .a    (op_a),
    .b    (op_b),
    .op   (ctrl.alu_op),
    .y    (alu_y),
    .zero (alu_zero)
  );

  // -------- RV32M divider (iterative, ~33 cycles) --------
  logic        div_done_int;
  logic        div_busy_int;
  logic [31:0] div_result_w;

  // Pulse start only on the first cycle the divide instruction is in EX,
  // and only if EX is valid (not a bubble) and div32 is currently idle
  // (not running, not holding a previous result).
  logic        div_start;
  assign div_start = ctrl.is_div
                  && valid
                  && !div_busy_int
                  && !div_done_int;

  // Acknowledge to div32: when EX/MEM captures and the instruction was a
  // divide, transition div32 from S_DONE -> S_IDLE.
  logic        div_ack;
  assign div_ack = ex_advance && ctrl.is_div && valid && div_done_int;

  div32 u_div32 (
    .clk      (clk),
    .rst_n    (rst_n),
    .start    (div_start),
    .dividend (rs1_data),
    .divisor  (rs2_data),
    .op       (ctrl.div_op),
    .ack      (div_ack),
    .busy     (div_busy_int),
    .done     (div_done_int),
    .result   (div_result_w)
  );

  // Core-visible stall: 1 while we have a divide in EX whose result hasn't
  // been produced yet. Drops to 0 the cycle div32 enters S_DONE so EX/MEM
  // can capture the same cycle.
  assign div_busy = ctrl.is_div && valid && !div_done_int;

  // -------- Result mux: divide result overrides ALU when applicable --------
  always_comb begin
    if (ctrl.is_div) alu_result = div_result_w;
    else             alu_result = alu_y;
  end

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

  assign branch_taken  = br_taken & valid;
  assign branch_target = br_tgt;

endmodule : execute

`default_nettype wire
