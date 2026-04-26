// =============================================================================
// core_props.sv — Procedural micro-architectural checks for the RV32I core.
//
// Bound to riscv_core. Verifies:
//   * x0 register file slot stays at zero (no writeback to x0 of non-zero data
//     should ever take effect — we check via the wb_we/wb_rd/wb_data ports).
//   * After a taken branch in EX, the IF/ID register's id_instr equals the
//     flushed-NOP encoding (0x00000013) for at least the next cycle.
//
// Procedural style (always_ff) for Icarus compatibility.
// =============================================================================
`default_nettype none

module core_props (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        wb_we,
  input  logic [4:0]  wb_rd,
  input  logic [31:0] wb_data,

  input  logic        ex_branch_taken,
  input  logic [31:0] id_instr
);

  logic        prev_ex_branch_taken;
  always_ff @(posedge clk) begin
    if (!rst_n) prev_ex_branch_taken <= 1'b0;
    else        prev_ex_branch_taken <= ex_branch_taken;
  end

  always_ff @(posedge clk) begin
    if (rst_n) begin
      // x0 should never be the destination of a non-zero writeback signal
      // (the regfile additionally guards against this; this check ensures
      // the upstream WB mux doesn't even try).
      if (wb_we && (wb_rd == 5'd0) && (wb_data != 32'd0)) begin
        $error("%0t: core property failed: writeback to x0 with non-zero data 0x%08x",
               $time, wb_data);
      end

      // After a taken branch (last cycle), the ID instruction this cycle
      // should be the squash NOP (0x00000013).
      if (prev_ex_branch_taken && (id_instr !== 32'h0000_0013)) begin
        $error("%0t: core property failed: ID stage not flushed after branch (id_instr=0x%08x)",
               $time, id_instr);
      end
    end
  end

endmodule : core_props

`default_nettype wire
