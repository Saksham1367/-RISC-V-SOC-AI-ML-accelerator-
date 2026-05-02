// =============================================================================
// riscv_core.sv — Top-level 5-stage in-order RV32IM core.
//
// Pipeline:
//   IF  : PC + synchronous instruction memory request
//   ID  : decode + regfile read
//   EX  : ALU / branch / RV32M MUL / RV32M DIV (iterative, stalls EX)
//   MEM : data memory access + load alignment
//   WB  : register-file writeback
//
// Forwarding (handled in hazard_unit + EX-stage operand muxes):
//   * MEM -> EX (priority): instruction in MEM forwards its "would-write"
//     value (load_aligned for loads, alu_result for ALU/MUL, pc+4 for JAL).
//   * WB  -> EX:            instruction in WB forwards its wb-mux value.
//   With single-cycle SRAM the MEM-stage load_aligned is combinational, so
//   load-use needs no stall — back-to-back load+use just forwards.
//
// Stalls:
//   * mem_stall — MEM has L/S and dmem_stall=1 (MMIO via AXI bridge etc).
//                 Holds MEM, EX/MEM, EX, ID/EX, ID, IF/ID, PC. MEM/WB takes
//                 a bubble so WB drains without re-writing.
//   * div_stall — EX has DIV and div32 not yet done. Holds EX, ID/EX, ID,
//                 IF/ID, PC. EX/MEM takes a bubble so MEM/WB still drains.
//
// Branches (resolved in EX): flush IF/ID and ID/EX. Branch penalty = 2.
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

  // data memory (single-cycle on local SRAM; the SoC interconnect raises
  // dmem_stall while routing via the AXI4-Lite bridge — the core then
  // freezes the MEM stage and everything upstream).
  output logic [31:0]  dmem_addr,
  output logic [31:0]  dmem_wdata,
  output logic [3:0]   dmem_wstrb,
  output logic         dmem_re,
  output logic         dmem_we,
  input  logic [31:0]  dmem_rdata,
  input  logic         dmem_stall
);

  // ===========================================================================
  // Forward declarations of cross-stage signals (so we can use them above
  // the FF blocks that drive them — Verilog allows it as long as we don't
  // create combinational loops, and we don't).
  // ===========================================================================
  logic        mem_stall;
  logic        div_stall;
  logic        ex_advance;
  logic        flush_if;

  // ===========================================================================
  // IF stage
  // ===========================================================================
  logic        stall_if;
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
  logic        stall_id_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      id_pc    <= '0;
      id_instr <= 32'h0000_0013;  // NOP (addi x0,x0,0)
      id_valid <= 1'b0;
    end else if (flush_if) begin
      id_pc    <= '0;
      id_instr <= 32'h0000_0013;
      id_valid <= 1'b0;
    end else if (stall_id_reg) begin
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

  decoder u_decoder (
    .instr (id_instr),
    .ctrl  (id_ctrl)
  );

  // Writeback wires (driven from WB stage below)
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

  // ===========================================================================
  // ID/EX pipeline register
  // ===========================================================================
  ctrl_t       ex_ctrl;
  logic        ex_valid;
  logic [31:0] ex_pc;
  logic [31:0] ex_rs1_data_raw, ex_rs2_data_raw;

  // EX register update conditions:
  //   hold on (mem_stall || div_stall): EX must not advance
  //   bubble on flush_if: branch in EX killed the next slot
  //   else advance from ID
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ex_ctrl         <= '0;
      ex_valid        <= 1'b0;
      ex_pc           <= '0;
      ex_rs1_data_raw <= '0;
      ex_rs2_data_raw <= '0;
    end else if (mem_stall || div_stall) begin
      // hold
      ex_ctrl         <= ex_ctrl;
      ex_valid        <= ex_valid;
      ex_pc           <= ex_pc;
      ex_rs1_data_raw <= ex_rs1_data_raw;
      ex_rs2_data_raw <= ex_rs2_data_raw;
    end else if (flush_if) begin
      // bubble — squash the slot behind a taken branch
      ex_ctrl         <= '0;
      ex_valid        <= 1'b0;
      ex_pc           <= '0;
      ex_rs1_data_raw <= '0;
      ex_rs2_data_raw <= '0;
    end else begin
      ex_ctrl         <= id_ctrl;
      ex_valid        <= id_valid;
      ex_pc           <= id_pc;
      ex_rs1_data_raw <= id_rs1_data_raw;
      ex_rs2_data_raw <= id_rs2_data_raw;
    end
  end

  // ===========================================================================
  // EX/MEM pipeline register (declarations needed for forwarding)
  // ===========================================================================
  ctrl_t       mem_ctrl;
  logic        mem_valid;
  logic [31:0] mem_pc;
  logic [31:0] mem_alu_result;
  logic [31:0] mem_rs2_data;

  // ===========================================================================
  // MEM/WB pipeline register (declarations needed for forwarding)
  // ===========================================================================
  ctrl_t       wb_ctrl;
  logic        wb_valid;
  logic [31:0] wb_pc;
  logic [31:0] wb_alu_result;
  logic [31:0] wb_load_aligned;

  // ===========================================================================
  // MEM stage — combinational outputs needed by forwarding & WB
  // ===========================================================================
  logic [31:0] mem_load_aligned;
  load_align u_load_align (
    .size        (mem_ctrl.mem_size),
    .is_unsigned (mem_ctrl.mem_unsigned),
    .byte_off    (mem_alu_result[1:0]),
    .mem_rdata   (dmem_rdata),
    .aligned     (mem_load_aligned)
  );

  // "Value MEM stage would write back" — used for MEM->EX forwarding.
  logic [31:0] mem_wb_value;
  always_comb begin
    unique case (mem_ctrl.wb_sel)
      WB_ALU:  mem_wb_value = mem_alu_result;
      WB_MEM:  mem_wb_value = mem_load_aligned;
      WB_PC4:  mem_wb_value = mem_pc + 32'd4;
      default: mem_wb_value = mem_alu_result;
    endcase
  end

  // ===========================================================================
  // WB stage — combinational mux + writeback
  // ===========================================================================
  logic [31:0] wb_value;
  always_comb begin
    unique case (wb_ctrl.wb_sel)
      WB_ALU:  wb_value = wb_alu_result;
      WB_MEM:  wb_value = wb_load_aligned;
      WB_PC4:  wb_value = wb_pc + 32'd4;
      default: wb_value = wb_alu_result;
    endcase
  end

  assign wb_we   = wb_ctrl.reg_we & wb_valid;
  assign wb_rd   = wb_ctrl.rd;
  assign wb_data = wb_value;

  // ===========================================================================
  // Forwarding (hazard unit) + EX operand muxes
  // ===========================================================================
  logic [1:0] fwd_a_sel, fwd_b_sel;

  hazard_unit u_hazard (
    .id_ex_rs1     (ex_ctrl.rs1),
    .id_ex_rs2     (ex_ctrl.rs2),
    .ex_mem_rd     (mem_ctrl.rd),
    .ex_mem_reg_we (mem_ctrl.reg_we),
    .ex_mem_valid  (mem_valid),
    .mem_wb_rd     (wb_ctrl.rd),
    .mem_wb_reg_we (wb_ctrl.reg_we),
    .mem_wb_valid  (wb_valid),
    .fwd_a_sel     (fwd_a_sel),
    .fwd_b_sel     (fwd_b_sel)
  );

  logic [31:0] ex_rs1_data, ex_rs2_data;
  always_comb begin
    unique case (fwd_a_sel)
      2'b10:   ex_rs1_data = mem_wb_value;
      2'b01:   ex_rs1_data = wb_value;
      default: ex_rs1_data = ex_rs1_data_raw;
    endcase
    unique case (fwd_b_sel)
      2'b10:   ex_rs2_data = mem_wb_value;
      2'b01:   ex_rs2_data = wb_value;
      default: ex_rs2_data = ex_rs2_data_raw;
    endcase
  end

  // ===========================================================================
  // EX stage
  // ===========================================================================
  logic [31:0] ex_alu_result;
  logic        ex_branch_taken;
  logic [31:0] ex_branch_target;
  logic        ex_div_busy;

  execute u_execute (
    .clk           (clk),
    .rst_n         (rst_n),
    .ctrl          (ex_ctrl),
    .pc            (ex_pc),
    .rs1_data      (ex_rs1_data),
    .rs2_data      (ex_rs2_data),
    .valid         (ex_valid),
    .ex_advance    (ex_advance),
    .alu_result    (ex_alu_result),
    .branch_taken  (ex_branch_taken),
    .branch_target (ex_branch_target),
    .div_busy      (ex_div_busy)
  );

  assign ex_pc_redirect        = ex_branch_taken;
  assign ex_pc_redirect_target = ex_branch_target;

  // ===========================================================================
  // EX/MEM pipeline register update
  //   hold on mem_stall (MEM-stage instr stays put)
  //   bubble on div_stall (EX is stuck on DIV; let MEM/WB drain)
  //   bubble on flush_if (taken branch — kill the slot moving from EX to MEM
  //                       only when EX held a real instr that needs to be
  //                       killed; but actually the branch instr itself is in
  //                       EX, and it has reg_we=0 for cond branches and
  //                       reg_we=1 for JAL — JAL must propagate normally.
  //                       So we DO want to advance EX->MEM here. flush_if is
  //                       only about killing the *next* slot, handled at
  //                       ID/EX.)
  //   else advance EX -> EX/MEM
  // ===========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_ctrl       <= '0;
      mem_valid      <= 1'b0;
      mem_pc         <= '0;
      mem_alu_result <= '0;
      mem_rs2_data   <= '0;
    end else if (mem_stall) begin
      // hold
      mem_ctrl       <= mem_ctrl;
      mem_valid      <= mem_valid;
      mem_pc         <= mem_pc;
      mem_alu_result <= mem_alu_result;
      mem_rs2_data   <= mem_rs2_data;
    end else if (div_stall) begin
      // bubble: EX still computing, send NOP to MEM
      mem_ctrl       <= '0;
      mem_valid      <= 1'b0;
      mem_pc         <= '0;
      mem_alu_result <= '0;
      mem_rs2_data   <= '0;
    end else begin
      mem_ctrl       <= ex_ctrl;
      mem_valid      <= ex_valid;
      mem_pc         <= ex_pc;
      mem_alu_result <= ex_alu_result;
      mem_rs2_data   <= ex_rs2_data;   // post-forwarding rs2 for stores
    end
  end

  // ===========================================================================
  // MEM stage — drive dmem from EX/MEM register
  // ===========================================================================
  assign dmem_addr = mem_alu_result;
  assign dmem_re   = mem_ctrl.mem_re & mem_valid;
  assign dmem_we   = mem_ctrl.mem_we & mem_valid;

  // store wstrb / aligned wdata
  logic [1:0] mem_byte_off;
  assign mem_byte_off = mem_alu_result[1:0];

  always_comb begin
    dmem_wdata = mem_rs2_data;
    dmem_wstrb = 4'h0;
    unique case (mem_ctrl.mem_size)
      MEM_B: begin
        dmem_wdata = {4{mem_rs2_data[7:0]}};
        dmem_wstrb = (mem_ctrl.mem_we & mem_valid)
                   ? (4'b0001 << mem_byte_off) : 4'h0;
      end
      MEM_H: begin
        dmem_wdata = {2{mem_rs2_data[15:0]}};
        dmem_wstrb = (mem_ctrl.mem_we & mem_valid)
                   ? (4'b0011 << mem_byte_off) : 4'h0;
      end
      MEM_W: begin
        dmem_wdata = mem_rs2_data;
        dmem_wstrb = (mem_ctrl.mem_we & mem_valid) ? 4'b1111 : 4'h0;
      end
      default: begin
        dmem_wdata = mem_rs2_data;
        dmem_wstrb = (mem_ctrl.mem_we & mem_valid) ? 4'b1111 : 4'h0;
      end
    endcase
  end

  // ===========================================================================
  // MEM/WB pipeline register update
  //   bubble on mem_stall (MEM is stuck — don't promote to WB)
  //   else advance MEM -> MEM/WB
  // ===========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wb_ctrl         <= '0;
      wb_valid        <= 1'b0;
      wb_pc           <= '0;
      wb_alu_result   <= '0;
      wb_load_aligned <= '0;
    end else if (mem_stall) begin
      wb_ctrl         <= '0;
      wb_valid        <= 1'b0;
      wb_pc           <= '0;
      wb_alu_result   <= '0;
      wb_load_aligned <= '0;
    end else begin
      wb_ctrl         <= mem_ctrl;
      wb_valid        <= mem_valid;
      wb_pc           <= mem_pc;
      wb_alu_result   <= mem_alu_result;
      wb_load_aligned <= mem_load_aligned;
    end
  end

  // ===========================================================================
  // Stall logic
  // ===========================================================================
  // MEM-side stall: dmem_stall asserted while a real load/store is in MEM
  assign mem_stall = (mem_ctrl.mem_re | mem_ctrl.mem_we) & mem_valid & dmem_stall;

  // EX-side stall: divide instruction in EX whose result isn't ready yet
  assign div_stall = ex_div_busy;

  // Stall propagation: any downstream stall freezes IF and IF/ID
  assign stall_if     = mem_stall | div_stall;
  assign stall_id_reg = mem_stall | div_stall;

  // ex_advance: pulses 1 the cycle EX/MEM register actually captures EX's
  // outputs. Used by execute.sv to ack the divider.
  assign ex_advance = !mem_stall && !div_stall;

  // ===========================================================================
  // Branch flush
  // ===========================================================================
  // Taken branch in EX squashes the two instructions behind it (in IF/ID
  // and currently being fetched). flush_if zeros IF/ID; ID/EX takes the
  // bubble path on flush_if too. The branch instruction itself (in EX) is
  // allowed to propagate to MEM/WB normally — JAL/JALR must writeback PC+4.
  assign flush_if = ex_branch_taken;

endmodule : riscv_core

`default_nettype wire
