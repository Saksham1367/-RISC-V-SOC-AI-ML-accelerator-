// =============================================================================
// load_align.sv — Aligns and sign/zero-extends data read from memory.
// LB/LBU/LH/LHU/LW.
// =============================================================================
`default_nettype none

import riscv_pkg::*;
module load_align(
  input  mem_size_e   size,
  input  logic        is_unsigned,
  input  logic [1:0]  byte_off,
  input  logic [31:0] mem_rdata,
  output logic [31:0] aligned
);

  logic [7:0]  byte_sel;
  logic [15:0] half_sel;

  always_comb begin
    unique case (byte_off)
      2'd0: byte_sel = mem_rdata[7:0];
      2'd1: byte_sel = mem_rdata[15:8];
      2'd2: byte_sel = mem_rdata[23:16];
      2'd3: byte_sel = mem_rdata[31:24];
    endcase
  end

  always_comb begin
    unique case (byte_off[1])
      1'b0: half_sel = mem_rdata[15:0];
      1'b1: half_sel = mem_rdata[31:16];
    endcase
  end

  always_comb begin
    unique case (size)
      MEM_B: aligned = is_unsigned ? {24'b0, byte_sel}
                                   : {{24{byte_sel[7]}}, byte_sel};
      MEM_H: aligned = is_unsigned ? {16'b0, half_sel}
                                   : {{16{half_sel[15]}}, half_sel};
      MEM_W: aligned = mem_rdata;
      default: aligned = mem_rdata;
    endcase
  end

endmodule : load_align

`default_nettype wire
