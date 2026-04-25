// =============================================================================
// sa_pkg.sv — Systolic-array shared parameters and types
// =============================================================================
`ifndef SA_PKG_SV
`define SA_PKG_SV

package sa_pkg;

  // -------- Default datapath widths --------
  // INT8 activation × INT8 weight, INT32 accumulator.
  localparam int unsigned DATA_W   = 8;
  localparam int unsigned WEIGHT_W = 8;
  localparam int unsigned ACC_W    = 32;

  // 4x4 grid (NxN). Other sizes work as long as you change ARRAY_N consistently.
  localparam int unsigned ARRAY_N  = 4;

endpackage : sa_pkg

`endif // SA_PKG_SV
