// =============================================================================
// sa_top.sv — 4×4 Output-Stationary Systolic Array Top
//
// Computes  C = A × B   (all NxN signed INT8 -> INT32 accumulators).
//
// Dataflow:
//   * row[i] of A enters from the west edge (a_west[i])
//   * col[j] of B enters from the north edge (b_north[j])
//   * each PE accumulates a*b every cycle that `valid_in` is high
//   * after K = N accumulations, PE[i][j].acc = C[i][j]
//
// Required input timing (staggering):
//   * a_west[i][k] and b_north[j][k] must arrive at PE[i][j] *on the same
//     cycle*. Because activations take j cycles to propagate east through the
//     row and weights take i cycles to propagate south through the column,
//     the input-buffer module must inject:
//
//       a_west[i] gets A[i][0] at cycle  i,
//                      A[i][1] at cycle  i+1,
//                      A[i][2] at cycle  i+2,
//                      A[i][3] at cycle  i+3.
//
//       b_north[j] gets B[0][j] at cycle  j,
//                       B[1][j] at cycle  j+1,
//                       B[2][j] at cycle  j+2,
//                       B[3][j] at cycle  j+3.
//
//   * `valid_in` for PE[i][j] arrives via the propagated `valid` signal —
//     the array's external `valid_west[i]` and `valid_north[j]` signals are
//     OR'd into the appropriate PEs (we simply pass valid alongside `a` from
//     the west; `b` from the north tracks the same valid). The host TB and
//     the input-buffer wrapper drive `valid_west` for K cycles starting at
//     row i's stagger offset.
//
// Output:
//   * `acc_out[i][j]` is the live PE accumulator. After K accumulations
//     (the host counts cycles), latch the array.
//
// =============================================================================
`default_nettype none

module sa_top
  import sa_pkg::*;
#(
  parameter int unsigned N        = sa_pkg::ARRAY_N,
  parameter int unsigned DATA_W   = sa_pkg::DATA_W,
  parameter int unsigned WEIGHT_W = sa_pkg::WEIGHT_W,
  parameter int unsigned ACC_W    = sa_pkg::ACC_W
)(
  input  logic                       clk,
  input  logic                       rst_n,

  // control
  input  logic                       acc_clear,            // pulse: zero all PE accumulators

  // west-edge activation inputs (one per row)
  input  logic signed [DATA_W-1:0]   a_west   [N],
  input  logic                       valid_west[N],        // matches a_west's row stagger

  // north-edge weight inputs (one per column)
  input  logic signed [WEIGHT_W-1:0] b_north  [N],

  // accumulator outputs (live values; host latches after K accumulations)
  output logic signed [ACC_W-1:0]    acc_out  [N][N]
);

  // -------- Inter-PE wires --------
  // Horizontal: a flowing east. h_a[i][j] is the activation entering PE[i][j].
  // h_a[i][0] = a_west[i]; h_a[i][j>0] = PE[i][j-1].a_out.
  logic signed [DATA_W-1:0]   h_a    [N][N+1];
  logic                       h_v    [N][N+1];

  // Vertical: b flowing south. v_b[i][j] is the weight entering PE[i][j].
  // v_b[0][j] = b_north[j]; v_b[i>0][j] = PE[i-1][j].b_out.
  logic signed [WEIGHT_W-1:0] v_b    [N+1][N];

  // Edge bindings
  for (genvar i = 0; i < N; i++) begin : g_west_edge
    assign h_a[i][0] = a_west[i];
    assign h_v[i][0] = valid_west[i];
  end
  for (genvar j = 0; j < N; j++) begin : g_north_edge
    assign v_b[0][j] = b_north[j];
  end

  // -------- PE grid --------
  for (genvar i = 0; i < N; i++) begin : g_row
    for (genvar j = 0; j < N; j++) begin : g_col
      pe #(
        .DATA_W   (DATA_W),
        .WEIGHT_W (WEIGHT_W),
        .ACC_W    (ACC_W)
      ) u_pe (
        .clk       (clk),
        .rst_n     (rst_n),
        .acc_clear (acc_clear),
        .a_in      (h_a[i][j]),
        .b_in      (v_b[i][j]),
        .valid_in  (h_v[i][j]),
        .a_out     (h_a[i][j+1]),
        .b_out     (v_b[i+1][j]),
        .valid_out (h_v[i][j+1]),
        .acc_out   (acc_out[i][j])
      );
    end
  end

endmodule : sa_top

`default_nettype wire
