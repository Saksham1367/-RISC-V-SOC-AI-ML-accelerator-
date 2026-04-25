// =============================================================================
// hazard_unit.sv — Resolves data and control hazards for the 3-stage pipeline.
//
// Pipeline:
//   IF  : PC -> imem
//   ID  : decode, regfile read
//   EX  : ALU / branch / mem
//
// Data hazards we handle:
//   * EX -> ID forwarding for ALU results (consumer in ID needs value being
//     produced this cycle by the instruction in EX).
//   * Load-use stall: if instruction in EX is a load and instruction in ID
//     reads the load's destination, stall ID for one cycle.
//
// Control hazards:
//   * Taken branch / jump in EX redirects PC and flushes IF/ID register.
// =============================================================================
`default_nettype none

module hazard_unit
  import riscv_pkg::*;
(
  // ID-stage operand sources
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,

  // EX-stage destination + control
  input  logic [4:0] ex_rd,
  input  logic       ex_reg_we,
  input  logic       ex_mem_re,    // load in EX -> potential load-use hazard

  // forwarding outputs (ID-stage operand mux selects)
  output logic       fwd_rs1,      // 1 = use ex_alu_result instead of regfile rs1
  output logic       fwd_rs2,

  // pipeline control
  output logic       stall_if,
  output logic       stall_id,
  output logic       bubble_ex     // insert NOP into EX next cycle (load-use)
);

  logic rs1_match, rs2_match;
  assign rs1_match = ex_reg_we && (ex_rd != 5'd0) && (ex_rd == id_rs1);
  assign rs2_match = ex_reg_we && (ex_rd != 5'd0) && (ex_rd == id_rs2);

  // load-use: load in EX, dependent op in ID
  logic load_use;
  assign load_use = ex_mem_re && (rs1_match || rs2_match);

  // forward (only when not load-use; load-use handles via stall)
  assign fwd_rs1 = rs1_match && !load_use;
  assign fwd_rs2 = rs2_match && !load_use;

  // stall on load-use: freeze IF and ID for one cycle, bubble EX
  assign stall_if  = load_use;
  assign stall_id  = load_use;
  assign bubble_ex = load_use;

endmodule : hazard_unit

`default_nettype wire
