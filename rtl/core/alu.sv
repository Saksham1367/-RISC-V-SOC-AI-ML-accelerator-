// alu.sv — RV32I + RV32M (multiply only) ALU
//
// MUL/MULH/MULHSU/MULHU are single-cycle here. The 64-bit product is computed
// once and the upper or lower 32 bits are selected by the alu_op. Synthesis on
// the Tang Nano 20K must NOT map this to DSP blocks — the 8x8 SEDA array
// claims all 48 GW2AR-18 DSPs. Yosys-side: rely on `(* mul2dsp = 0 *)` or
// the synth_gowin -nodsp pass when we get to FPGA bring-up.
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

  // ---- RV32M multiply ----
  // Three 64-bit products: signed*signed, signed*unsigned, unsigned*unsigned.
  // MULH    -> upper 32 of signed*signed
  // MULHSU  -> upper 32 of signed(rs1)*unsigned(rs2)
  // MULHU   -> upper 32 of unsigned*unsigned
  // MUL     -> lower 32 (sign-irrelevant)
  logic signed [63:0] prod_ss;
  logic signed [63:0] prod_su;
  logic        [63:0] prod_uu;

  assign prod_ss = $signed(a) * $signed(b);
  // signed*unsigned: extend `a` with its sign bit, extend `b` with zero.
  assign prod_su = $signed({a[XLEN-1], a}) * $signed({1'b0, b});
  assign prod_uu = a * b;

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
      ALU_MUL:    y = prod_ss[31:0];
      ALU_MULH:   y = prod_ss[63:32];
      ALU_MULHSU: y = prod_su[63:32];
      ALU_MULHU:  y = prod_uu[63:32];
      default:    y = '0;
    endcase
  end

  assign zero = (y == '0);

endmodule : alu

`default_nettype wire
