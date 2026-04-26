// =============================================================================
// branch_unit.sv — Evaluates branch condition for RV32I.
// Combinational. Used in the EX stage.
// =============================================================================
`default_nettype none

import riscv_pkg::*;
module branch_unit(
  input  br_type_e   br_type,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        taken
);

  always_comb begin
    unique case (br_type)
      BR_NONE: taken = 1'b0;
      BR_EQ:   taken = (a == b);
      BR_NE:   taken = (a != b);
      BR_LT:   taken = ($signed(a) <  $signed(b));
      BR_GE:   taken = ($signed(a) >= $signed(b));
      BR_LTU:  taken = (a <  b);
      BR_GEU:  taken = (a >= b);
      BR_JAL:  taken = 1'b1;  // unconditional jump (JAL/JALR)
      default: taken = 1'b0;
    endcase
  end

endmodule : branch_unit

`default_nettype wire
