// =============================================================================
// hazard_unit.sv — Forwarding muxes for the 5-stage pipeline.
//
// Pipeline:
//   IF -> ID -> EX -> MEM -> WB
//
// Data hazards we handle (forwarding only — no load-use stall is needed
// because single-cycle SRAM + MEM-stage load_align produces the load value
// combinationally for MEM->EX forwarding the cycle after the load was in EX):
//
//   * MEM -> EX forward (priority): if the instruction in MEM stage is going
//     to write a register that EX-stage source reads, forward the MEM
//     stage's "would-write" value (load_aligned for loads, alu_result for
//     ALU/MUL, pc+4 for JAL).
//   * WB  -> EX forward: same idea, one stage later.
//
// Priority: MEM forward beats WB forward (MEM is the more recent producer).
//
// Stalls (mem_stall from MMIO and div_stall from iterative DIV) are handled
// in riscv_core.sv directly — they're not data-forwarding concerns.
// =============================================================================
`default_nettype none

module hazard_unit
  import riscv_pkg::*;
(
  // ID/EX register source operands (the instruction currently in EX)
  input  logic [4:0] id_ex_rs1,
  input  logic [4:0] id_ex_rs2,

  // EX/MEM register destination (instruction currently in MEM)
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_reg_we,
  input  logic       ex_mem_valid,

  // MEM/WB register destination (instruction currently in WB)
  input  logic [4:0] mem_wb_rd,
  input  logic       mem_wb_reg_we,
  input  logic       mem_wb_valid,

  // Forwarding mux selects:
  //   2'b00 = regfile (no forward)
  //   2'b01 = WB-stage value
  //   2'b10 = MEM-stage value (highest priority)
  output logic [1:0] fwd_a_sel,
  output logic [1:0] fwd_b_sel
);

  logic mem_a_match, mem_b_match;
  logic wb_a_match,  wb_b_match;

  assign mem_a_match = ex_mem_valid && ex_mem_reg_we
                    && (ex_mem_rd != 5'd0)
                    && (ex_mem_rd == id_ex_rs1);
  assign mem_b_match = ex_mem_valid && ex_mem_reg_we
                    && (ex_mem_rd != 5'd0)
                    && (ex_mem_rd == id_ex_rs2);

  assign wb_a_match  = mem_wb_valid && mem_wb_reg_we
                    && (mem_wb_rd != 5'd0)
                    && (mem_wb_rd == id_ex_rs1);
  assign wb_b_match  = mem_wb_valid && mem_wb_reg_we
                    && (mem_wb_rd != 5'd0)
                    && (mem_wb_rd == id_ex_rs2);

  always_comb begin
    if      (mem_a_match) fwd_a_sel = 2'b10;
    else if (wb_a_match)  fwd_a_sel = 2'b01;
    else                  fwd_a_sel = 2'b00;

    if      (mem_b_match) fwd_b_sel = 2'b10;
    else if (wb_b_match)  fwd_b_sel = 2'b01;
    else                  fwd_b_sel = 2'b00;
  end

endmodule : hazard_unit

`default_nettype wire
