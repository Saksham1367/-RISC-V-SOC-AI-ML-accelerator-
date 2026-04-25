// =============================================================================
// riscv_pkg.sv — RV32I opcodes, funct3/funct7 encodings, ALU op codes
// =============================================================================
`ifndef RISCV_PKG_SV
`define RISCV_PKG_SV

package riscv_pkg;

  // ---------------------------------------------------------------------------
  // RV32I major opcodes (instr[6:0])
  // ---------------------------------------------------------------------------
  localparam logic [6:0] OPC_LUI    = 7'b0110111;
  localparam logic [6:0] OPC_AUIPC  = 7'b0010111;
  localparam logic [6:0] OPC_JAL    = 7'b1101111;
  localparam logic [6:0] OPC_JALR   = 7'b1100111;
  localparam logic [6:0] OPC_BRANCH = 7'b1100011;
  localparam logic [6:0] OPC_LOAD   = 7'b0000011;
  localparam logic [6:0] OPC_STORE  = 7'b0100011;
  localparam logic [6:0] OPC_OP_IMM = 7'b0010011;
  localparam logic [6:0] OPC_OP     = 7'b0110011;
  localparam logic [6:0] OPC_FENCE  = 7'b0001111;
  localparam logic [6:0] OPC_SYSTEM = 7'b1110011;

  // ---------------------------------------------------------------------------
  // funct3 fields
  // ---------------------------------------------------------------------------
  // BRANCH
  localparam logic [2:0] F3_BEQ  = 3'b000;
  localparam logic [2:0] F3_BNE  = 3'b001;
  localparam logic [2:0] F3_BLT  = 3'b100;
  localparam logic [2:0] F3_BGE  = 3'b101;
  localparam logic [2:0] F3_BLTU = 3'b110;
  localparam logic [2:0] F3_BGEU = 3'b111;

  // LOAD
  localparam logic [2:0] F3_LB  = 3'b000;
  localparam logic [2:0] F3_LH  = 3'b001;
  localparam logic [2:0] F3_LW  = 3'b010;
  localparam logic [2:0] F3_LBU = 3'b100;
  localparam logic [2:0] F3_LHU = 3'b101;

  // STORE
  localparam logic [2:0] F3_SB = 3'b000;
  localparam logic [2:0] F3_SH = 3'b001;
  localparam logic [2:0] F3_SW = 3'b010;

  // OP / OP-IMM
  localparam logic [2:0] F3_ADD_SUB = 3'b000;
  localparam logic [2:0] F3_SLL     = 3'b001;
  localparam logic [2:0] F3_SLT     = 3'b010;
  localparam logic [2:0] F3_SLTU    = 3'b011;
  localparam logic [2:0] F3_XOR     = 3'b100;
  localparam logic [2:0] F3_SRL_SRA = 3'b101;
  localparam logic [2:0] F3_OR      = 3'b110;
  localparam logic [2:0] F3_AND     = 3'b111;

  // ---------------------------------------------------------------------------
  // ALU operation codes (internal to the core, not RISC-V spec)
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    ALU_ADD  = 4'd0,
    ALU_SUB  = 4'd1,
    ALU_AND  = 4'd2,
    ALU_OR   = 4'd3,
    ALU_XOR  = 4'd4,
    ALU_SLL  = 4'd5,
    ALU_SRL  = 4'd6,
    ALU_SRA  = 4'd7,
    ALU_SLT  = 4'd8,
    ALU_SLTU = 4'd9,
    ALU_PASS_B = 4'd10  // pass operand B through (for LUI)
  } alu_op_e;

  // ---------------------------------------------------------------------------
  // ALU operand source mux selects
  // ---------------------------------------------------------------------------
  typedef enum logic [0:0] {
    SRC_A_REG = 1'b0,  // ALU A = rs1
    SRC_A_PC  = 1'b1   // ALU A = PC (for AUIPC, JAL target)
  } src_a_e;

  typedef enum logic [0:0] {
    SRC_B_REG = 1'b0,  // ALU B = rs2
    SRC_B_IMM = 1'b1   // ALU B = imm
  } src_b_e;

  // ---------------------------------------------------------------------------
  // Writeback mux selects
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    WB_ALU  = 2'd0,  // rd <= ALU result
    WB_MEM  = 2'd1,  // rd <= load data (sign/zero extended)
    WB_PC4  = 2'd2   // rd <= PC + 4 (for JAL/JALR link)
  } wb_sel_e;

  // ---------------------------------------------------------------------------
  // Branch type encoding
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    BR_NONE = 3'd0,
    BR_EQ   = 3'd1,
    BR_NE   = 3'd2,
    BR_LT   = 3'd3,
    BR_GE   = 3'd4,
    BR_LTU  = 3'd5,
    BR_GEU  = 3'd6,
    BR_JAL  = 3'd7   // unconditional (JAL or JALR)
  } br_type_e;

  // ---------------------------------------------------------------------------
  // Memory access size (for load/store)
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    MEM_B = 2'b00,  // byte
    MEM_H = 2'b01,  // halfword
    MEM_W = 2'b10   // word
  } mem_size_e;

  // ---------------------------------------------------------------------------
  // Bundle of decoded control signals (output of decode stage)
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic        reg_we;       // register file write enable
    logic        mem_re;       // memory read enable (load)
    logic        mem_we;       // memory write enable (store)
    logic        mem_unsigned; // for LBU / LHU
    mem_size_e   mem_size;     // byte/half/word
    alu_op_e     alu_op;
    src_a_e      src_a_sel;
    src_b_e      src_b_sel;
    wb_sel_e     wb_sel;
    br_type_e    br_type;
    logic        is_jump;      // JAL or JALR — unconditional
    logic        is_jalr;      // JALR specifically (target uses rs1+imm)
    logic [31:0] imm;
    logic [4:0]  rs1;
    logic [4:0]  rs2;
    logic [4:0]  rd;
    logic        illegal;
  } ctrl_t;

endpackage : riscv_pkg

`endif // RISCV_PKG_SV
