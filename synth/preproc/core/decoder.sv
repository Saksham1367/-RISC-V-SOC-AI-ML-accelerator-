// =============================================================================
// decoder.sv — RV32I instruction decoder
// Pure combinational. Produces a ctrl_t bundle that the EX stage consumes.
// =============================================================================
`default_nettype none

import riscv_pkg::*;
module decoder(
  input  logic [31:0] instr,
  output ctrl_t       ctrl
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic [31:0] imm_value;

  assign opcode = instr[6:0];
  assign funct3 = instr[14:12];
  assign funct7 = instr[31:25];

  imm_gen u_immgen (
    .instr (instr),
    .imm   (imm_value)
  );

  always_comb begin
    // Defaults: NOP-like, illegal flagged off
    ctrl = '0;
    ctrl.alu_op       = ALU_ADD;
    ctrl.src_a_sel    = SRC_A_REG;
    ctrl.src_b_sel    = SRC_B_REG;
    ctrl.wb_sel       = WB_ALU;
    ctrl.br_type      = BR_NONE;
    ctrl.mem_size     = MEM_W;
    ctrl.mem_unsigned = 1'b0;
    ctrl.imm          = imm_value;
    ctrl.rs1          = instr[19:15];
    ctrl.rs2          = instr[24:20];
    ctrl.rd           = instr[11:7];
    ctrl.illegal      = 1'b0;

    unique case (opcode)
      // ----------------------------------------------------------------
      // LUI: rd = imm << 12
      // ----------------------------------------------------------------
      OPC_LUI: begin
        ctrl.reg_we    = 1'b1;
        ctrl.alu_op    = ALU_PASS_B;
        ctrl.src_b_sel = SRC_B_IMM;
      end

      // ----------------------------------------------------------------
      // AUIPC: rd = PC + (imm << 12)
      // ----------------------------------------------------------------
      OPC_AUIPC: begin
        ctrl.reg_we    = 1'b1;
        ctrl.alu_op    = ALU_ADD;
        ctrl.src_a_sel = SRC_A_PC;
        ctrl.src_b_sel = SRC_B_IMM;
      end

      // ----------------------------------------------------------------
      // JAL: rd = PC + 4; PC = PC + imm
      // ----------------------------------------------------------------
      OPC_JAL: begin
        ctrl.reg_we  = 1'b1;
        ctrl.wb_sel  = WB_PC4;
        ctrl.is_jump = 1'b1;
        ctrl.br_type = BR_JAL;
      end

      // ----------------------------------------------------------------
      // JALR: rd = PC + 4; PC = (rs1 + imm) & ~1
      // ----------------------------------------------------------------
      OPC_JALR: begin
        ctrl.reg_we    = 1'b1;
        ctrl.wb_sel    = WB_PC4;
        ctrl.is_jump   = 1'b1;
        ctrl.is_jalr   = 1'b1;
        ctrl.br_type   = BR_JAL;
        ctrl.alu_op    = ALU_ADD;
        ctrl.src_b_sel = SRC_B_IMM;
      end

      // ----------------------------------------------------------------
      // BRANCH: BEQ/BNE/BLT/BGE/BLTU/BGEU
      // ALU computes branch target via PC+imm in a separate adder; ALU
      // result is unused for control flow but we leave it as ADD for sim.
      // ----------------------------------------------------------------
      OPC_BRANCH: begin
        ctrl.reg_we = 1'b0;
        unique case (funct3)
          F3_BEQ:  ctrl.br_type = BR_EQ;
          F3_BNE:  ctrl.br_type = BR_NE;
          F3_BLT:  ctrl.br_type = BR_LT;
          F3_BGE:  ctrl.br_type = BR_GE;
          F3_BLTU: ctrl.br_type = BR_LTU;
          F3_BGEU: ctrl.br_type = BR_GEU;
          default: ctrl.illegal = 1'b1;
        endcase
      end

      // ----------------------------------------------------------------
      // LOAD: rd = MEM[rs1 + imm]
      // ----------------------------------------------------------------
      OPC_LOAD: begin
        ctrl.reg_we    = 1'b1;
        ctrl.mem_re    = 1'b1;
        ctrl.alu_op    = ALU_ADD;
        ctrl.src_b_sel = SRC_B_IMM;
        ctrl.wb_sel    = WB_MEM;
        unique case (funct3)
          F3_LB:  begin ctrl.mem_size = MEM_B; ctrl.mem_unsigned = 1'b0; end
          F3_LH:  begin ctrl.mem_size = MEM_H; ctrl.mem_unsigned = 1'b0; end
          F3_LW:  begin ctrl.mem_size = MEM_W; ctrl.mem_unsigned = 1'b0; end
          F3_LBU: begin ctrl.mem_size = MEM_B; ctrl.mem_unsigned = 1'b1; end
          F3_LHU: begin ctrl.mem_size = MEM_H; ctrl.mem_unsigned = 1'b1; end
          default: ctrl.illegal = 1'b1;
        endcase
      end

      // ----------------------------------------------------------------
      // STORE: MEM[rs1 + imm] = rs2
      // ----------------------------------------------------------------
      OPC_STORE: begin
        ctrl.reg_we    = 1'b0;
        ctrl.mem_we    = 1'b1;
        ctrl.alu_op    = ALU_ADD;
        ctrl.src_b_sel = SRC_B_IMM;
        unique case (funct3)
          F3_SB: ctrl.mem_size = MEM_B;
          F3_SH: ctrl.mem_size = MEM_H;
          F3_SW: ctrl.mem_size = MEM_W;
          default: ctrl.illegal = 1'b1;
        endcase
      end

      // ----------------------------------------------------------------
      // OP-IMM: ADDI / SLTI / SLTIU / XORI / ORI / ANDI / SLLI / SRLI / SRAI
      // ----------------------------------------------------------------
      OPC_OP_IMM: begin
        ctrl.reg_we    = 1'b1;
        ctrl.src_b_sel = SRC_B_IMM;
        unique case (funct3)
          F3_ADD_SUB: ctrl.alu_op = ALU_ADD;       // ADDI
          F3_SLT:     ctrl.alu_op = ALU_SLT;       // SLTI
          F3_SLTU:    ctrl.alu_op = ALU_SLTU;      // SLTIU
          F3_XOR:     ctrl.alu_op = ALU_XOR;       // XORI
          F3_OR:      ctrl.alu_op = ALU_OR;        // ORI
          F3_AND:     ctrl.alu_op = ALU_AND;       // ANDI
          F3_SLL:     ctrl.alu_op = ALU_SLL;       // SLLI
          F3_SRL_SRA: begin
            if (funct7[5]) ctrl.alu_op = ALU_SRA;  // SRAI
            else           ctrl.alu_op = ALU_SRL;  // SRLI
          end
          default:    ctrl.illegal = 1'b1;
        endcase
      end

      // ----------------------------------------------------------------
      // OP (R-type): ADD/SUB AND/OR/XOR SLL/SRL/SRA SLT/SLTU
      // ----------------------------------------------------------------
      OPC_OP: begin
        ctrl.reg_we    = 1'b1;
        ctrl.src_b_sel = SRC_B_REG;
        unique case (funct3)
          F3_ADD_SUB: begin
            if (funct7[5]) ctrl.alu_op = ALU_SUB;
            else           ctrl.alu_op = ALU_ADD;
          end
          F3_SLL:     ctrl.alu_op = ALU_SLL;
          F3_SLT:     ctrl.alu_op = ALU_SLT;
          F3_SLTU:    ctrl.alu_op = ALU_SLTU;
          F3_XOR:     ctrl.alu_op = ALU_XOR;
          F3_SRL_SRA: begin
            if (funct7[5]) ctrl.alu_op = ALU_SRA;
            else           ctrl.alu_op = ALU_SRL;
          end
          F3_OR:      ctrl.alu_op = ALU_OR;
          F3_AND:     ctrl.alu_op = ALU_AND;
          default:    ctrl.illegal = 1'b1;
        endcase
      end

      OPC_FENCE:  begin /* NOP for single-core */ end
      OPC_SYSTEM: begin /* ECALL/EBREAK: stub — treat as NOP */ end

      default: ctrl.illegal = 1'b1;
    endcase
  end

endmodule : decoder

`default_nettype wire
