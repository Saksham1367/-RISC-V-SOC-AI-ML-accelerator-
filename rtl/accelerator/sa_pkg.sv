// =============================================================================
// sa_pkg.sv — Systolic array shared parameters and types
// =============================================================================
`ifndef SA_PKG_SV
`define SA_PKG_SV

package sa_pkg;

  // -------- Default datapath widths --------
  // Each PE: INT8 input × INT8 weight, INT32 accumulator.
  localparam int unsigned DATA_W   = 8;
  localparam int unsigned WEIGHT_W = 8;
  localparam int unsigned ACC_W    = 32;
  localparam int unsigned ARRAY_N  = 4;   // 4×4 grid

endpackage : sa_pkg

`endif // SA_PKG_SV
