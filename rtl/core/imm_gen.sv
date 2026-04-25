// =============================================================================
// imm_gen.sv — RV32I immediate generator (combinational)
// Decodes the immediate value from the instruction word according to type.
// =============================================================================
`default_nettype none

module imm_gen
  import riscv_pkg::*;
(
  input  logic [31:0] instr,
  output logic [31:0] imm
);

  logic [6:0] opcode;
  assign opcode = instr[6:0];

  // I-type: instr[31:20], sign-extended
  logic [31:0] imm_i;
  assign imm_i = {{20{instr[31]}}, instr[31:20]};

  // S-type: instr[31:25] | instr[11:7], sign-extended
  logic [31:0] imm_s;
  assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};

  // B-type: instr[31] | instr[7] | instr[30:25] | instr[11:8] | 0
  logic [31:0] imm_b;
  assign imm_b = {{19{instr[31]}}, instr[31], instr[7],
                  instr[30:25], instr[11:8], 1'b0};

  // U-type: instr[31:12] << 12
  logic [31:0] imm_u;
  assign imm_u = {instr[31:12], 12'b0};

  // J-type: instr[31] | instr[19:12] | instr[20] | instr[30:21] | 0
  logic [31:0] imm_j;
  assign imm_j = {{11{instr[31]}}, instr[31], instr[19:12],
                  instr[20], instr[30:21], 1'b0};

  always_comb begin
    unique case (opcode)
      OPC_OP_IMM, OPC_LOAD, OPC_JALR: imm = imm_i;
      OPC_STORE:                      imm = imm_s;
      OPC_BRANCH:                     imm = imm_b;
      OPC_LUI, OPC_AUIPC:             imm = imm_u;
      OPC_JAL:                        imm = imm_j;
      OPC_SYSTEM:                     imm = imm_i;  // ecall/ebreak don't use it
      default:                        imm = 32'h0;
    endcase
  end

endmodule : imm_gen

`default_nettype wire
