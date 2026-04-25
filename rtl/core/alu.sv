// =============================================================================
// alu.sv — RV32I ALU
// Combinational. Width is parameterised but RV32I uses 32 bits.
// =============================================================================
`default_nettype none

module alu
  import riscv_pkg::*;
#(
  parameter int unsigned XLEN = 32
)(
  input  logic [XLEN-1:0] a,
  input  logic [XLEN-1:0] b,
  input  alu_op_e         op,
  output logic [XLEN-1:0] y,
  output logic            zero
);

  logic [XLEN-1:0] add_sub;
  logic            slt_signed;
  logic            slt_unsigned;
  logic [4:0]      shamt;

  assign shamt        = b[4:0];
  assign add_sub      = (op == ALU_SUB) ? (a - b) : (a + b);
  assign slt_signed   = ($signed(a) < $signed(b));
  assign slt_unsigned = (a < b);

  always_comb begin
    unique case (op)
      ALU_ADD:    y = add_sub;
      ALU_SUB:    y = add_sub;
      ALU_AND:    y = a & b;
      ALU_OR:     y = a | b;
      ALU_XOR:    y = a ^ b;
      ALU_SLL:    y = a << shamt;
      ALU_SRL:    y = a >> shamt;
      ALU_SRA:    y = $signed(a) >>> shamt;
      ALU_SLT:    y = {{(XLEN-1){1'b0}}, slt_signed};
      ALU_SLTU:   y = {{(XLEN-1){1'b0}}, slt_unsigned};
      ALU_PASS_B: y = b;
      default:    y = '0;
    endcase
  end

  assign zero = (y == '0);

endmodule : alu

`default_nettype wire
