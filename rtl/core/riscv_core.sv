// =============================================================================
// riscv_core.sv — Top-level 3-stage in-order RV32I core.
//
// Pipeline:
//   Stage 1 IF  : PC + synchronous instruction memory request
//   Stage 2 ID  : decode + regfile read
//   Stage 3 EX  : ALU / branch / data-memory access / writeback
//
// Notes:
//   * Synchronous IMEM: instruction returned on the cycle AFTER PC is presented.
//     The fetch module captures PC and exposes (if_pc, if_instr) aligned with
//     the rdata, which the IF/ID register then latches.
//   * Loads complete in EX; the SRAM model returns rdata in the same cycle
//     (single-cycle DMEM). For the v1 SoC the SRAM is single-cycle on read.
//   * Forwarding: EX -> ID for ALU outputs; load-use stalls 1 cycle.
// =============================================================================
`default_nettype none

module riscv_core
  import riscv_pkg::*;
#(
  parameter logic [31:0] RESET_PC = 32'h0000_0000
)(
  input  logic         clk,
  input  logic         rst_n,

  // instruction memory (synchronous, 1-cycle latency)
  output logic [31:0]  imem_addr,
  output logic         imem_re,
  input  logic [31:0]  imem_rdata,

  // data memory (synchronous, 1-cycle latency on rdata)
  output logic [31:0]  dmem_addr,
  output logic [31:0]  dmem_wdata,
  output logic [3:0]   dmem_wstrb,
  output logic         dmem_re,
  output logic         dmem_we,
  input  logic [31:0]  dmem_rdata
);

  // ===========================================================================
  // IF stage
  // ===========================================================================
  logic        stall_if, stall_id, bubble_ex;
  logic        flush_if;
  logic [31:0] if_pc, if_instr;
  logic        if_valid;

  // Branch redirect from EX
  logic        ex_pc_redirect;
  logic [31:0] ex_pc_redirect_target;

  fetch #(.RESET_PC(RESET_PC)) u_fetch (
    .clk                 (clk),
    .rst_n               (rst_n),
    .stall               (stall_if),
    .flush               (flush_if),
    .pc_redirect         (ex_pc_redirect),
    .pc_redirect_target  (ex_pc_redirect_target),
    .imem_addr           (imem_addr),
    .imem_re             (imem_re),
    .imem_rdata          (imem_rdata),
    .if_pc               (if_pc),
    .if_instr            (if_instr),
    .if_valid            (if_valid)
  );

  // ===========================================================================
  // IF/ID pipeline register
  // ===========================================================================
  logic [31:0] id_pc, id_instr;
  logic        id_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      id_pc    <= '0;
      id_instr <= 32'h0000_0013;  // NOP (addi x0,x0,0)
      id_valid <= 1'b0;
    end else if (flush_if) begin
      id_pc    <= '0;
      id_instr <= 32'h0000_0013;  // squash to NOP
      id_valid <= 1'b0;
    end else if (stall_id) begin
      // hold values
      id_pc    <= id_pc;
      id_instr <= id_instr;
      id_valid <= id_valid;
    end else begin
      id_pc    <= if_pc;
      id_instr <= if_instr;
      id_valid <= if_valid;
    end
  end

  // ===========================================================================
  // ID stage
  // ===========================================================================
  ctrl_t       id_ctrl;
  logic [31:0] id_rs1_data_raw, id_rs2_data_raw;
  logic [31:0] id_rs1_data, id_rs2_data;

  decoder u_decoder (
    .instr (id_instr),
    .ctrl  (id_ctrl)
  );

  // forward selects (combinational from EX writeback target)
  logic fwd_rs1, fwd_rs2;
  ctrl_t       ex_ctrl;
  logic [31:0] ex_alu_result;

  // EX-stage forwarding: when EX produces a value rd needs in ID this cycle.
  // We use the ALU result (works for ALU ops, JAL/JALR link is via WB_PC4 path
  // and is separately handled via ex_wb_value below).
  logic [31:0] ex_wb_value;

  // ===========================================================================
  // Register file
  // ===========================================================================
  // Writeback occurs at end of EX (synchronous). The regfile has internal
  // write-before-read bypass, so the next-cycle read sees the new value.
  logic        wb_we;
  logic [4:0]  wb_rd;
  logic [31:0] wb_data;

  regfile u_regfile (
    .clk      (clk),
    .rst_n    (rst_n),
    .rs1_addr (id_ctrl.rs1),
    .rs2_addr (id_ctrl.rs2),
    .rs1_data (id_rs1_data_raw),
    .rs2_data (id_rs2_data_raw),
    .we       (wb_we),
    .rd_addr  (wb_rd),
    .rd_data  (wb_data)
  );

  // EX -> ID operand forwarding
  assign id_rs1_data = fwd_rs1 ? ex_wb_value : id_rs1_data_raw;
  assign id_rs2_data = fwd_rs2 ? ex_wb_value : id_rs2_data_raw;

  // ===========================================================================
  // Hazard unit
  // ===========================================================================
  hazard_unit u_hazard (
    .id_rs1     (id_ctrl.rs1),
    .id_rs2     (id_ctrl.rs2),
    .ex_rd      (ex_ctrl.rd),
    .ex_reg_we  (ex_ctrl.reg_we),
    .ex_mem_re  (ex_ctrl.mem_re),
    .fwd_rs1    (fwd_rs1),
    .fwd_rs2    (fwd_rs2),
    .stall_if   (stall_if),
    .stall_id   (stall_id),
    .bubble_ex  (bubble_ex)
  );

  // ===========================================================================
  // ID/EX pipeline register
  // ===========================================================================
  logic [31:0] ex_pc;
  logic [31:0] ex_rs1_data, ex_rs2_data;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ex_ctrl     <= '0;
      ex_pc       <= '0;
      ex_rs1_data <= '0;
      ex_rs2_data <= '0;
    end else if (bubble_ex || flush_if) begin
      // Insert NOP bubble: zero out control so nothing is written/branched
      ex_ctrl     <= '0;
      ex_pc       <= '0;
      ex_rs1_data <= '0;
      ex_rs2_data <= '0;
    end else begin
      ex_ctrl     <= id_ctrl;
      ex_pc       <= id_pc;
      ex_rs1_data <= id_rs1_data;
      ex_rs2_data <= id_rs2_data;
    end
  end

  // ===========================================================================
  // EX stage
  // ===========================================================================
  logic        ex_branch_taken;
  logic [31:0] ex_branch_target;

  execute u_execute (
    .ctrl          (ex_ctrl),
    .pc            (ex_pc),
    .rs1_data      (ex_rs1_data),
    .rs2_data      (ex_rs2_data),
    .alu_result    (ex_alu_result),
    .branch_taken  (ex_branch_taken),
    .branch_target (ex_branch_target),
    .dmem_addr     (dmem_addr),
    .dmem_wdata    (dmem_wdata),
    .dmem_wstrb    (dmem_wstrb),
    .dmem_re       (dmem_re),
    .dmem_we       (dmem_we)
  );

  // -------- branch / jump redirect --------
  assign ex_pc_redirect        = ex_branch_taken;
  assign ex_pc_redirect_target = ex_branch_target;
  assign flush_if              = ex_branch_taken;

  // -------- writeback value mux --------
  logic [31:0] load_aligned;
  load_align u_load_align (
    .size        (ex_ctrl.mem_size),
    .is_unsigned (ex_ctrl.mem_unsigned),
    .byte_off    (dmem_addr[1:0]),
    .mem_rdata   (dmem_rdata),
    .aligned     (load_aligned)
  );

  always_comb begin
    unique case (ex_ctrl.wb_sel)
      WB_ALU: ex_wb_value = ex_alu_result;
      WB_MEM: ex_wb_value = load_aligned;
      WB_PC4: ex_wb_value = ex_pc + 32'd4;
      default: ex_wb_value = ex_alu_result;
    endcase
  end

  assign wb_we   = ex_ctrl.reg_we;
  assign wb_rd   = ex_ctrl.rd;
  assign wb_data = ex_wb_value;

endmodule : riscv_core

`default_nettype wire
