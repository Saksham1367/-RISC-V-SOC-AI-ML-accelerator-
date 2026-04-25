// =============================================================================
// sa_buffer.sv — Stagger / drive logic for the systolic array.
//
// Wraps `sa_top` with:
//   * A simple FSM that, given two NxN matrices A and B preloaded into
//     internal buffers, streams them into the array with the correct
//     skew (A[i][k] enters row i at cycle i+k; B[k][j] enters column j
//     at cycle k+j) and pulses valid for the right K cycles.
//   * A latch register that captures the NxN accumulators when the
//     array has finished (cycle = 2*(N-1) + N from start).
//   * `start` / `done` handshake.
//
// External usage:
//   * After reset, host writes A[i][k] and B[k][j] to the input buffers
//     (a_mat / b_mat ports — write-port style for v1).
//   * Host pulses `start`. Buffer asserts `busy`, drives the array, and
//     finally asserts `done` for one cycle once `c_mat` is valid.
//   * `c_mat` mirrors the captured 4×4 INT32 result; valid until the next
//     `start`.
//
// =============================================================================
`default_nettype none

module sa_buffer
  import sa_pkg::*;
#(
  parameter int unsigned N        = sa_pkg::ARRAY_N,
  parameter int unsigned DATA_W   = sa_pkg::DATA_W,
  parameter int unsigned WEIGHT_W = sa_pkg::WEIGHT_W,
  parameter int unsigned ACC_W    = sa_pkg::ACC_W
)(
  input  logic                       clk,
  input  logic                       rst_n,

  // pre-loaded operand matrices (v1: parallel write, no AXI yet)
  // Flattened 1D unpacked arrays — index as i*N+j — to keep the cocotb VPI
  // path simple. Internal logic re-views them as 2D matrices.
  input  logic signed [DATA_W-1:0]   a_mat [N*N],
  input  logic signed [WEIGHT_W-1:0] b_mat [N*N],

  // control / status
  input  logic                       start,
  output logic                       busy,
  output logic                       done,

  // result (flattened, same convention)
  output logic signed [ACC_W-1:0]    c_mat [N*N]
);

  // ---------------------------------------------------------------------
  // FSM cycle counter
  //
  // Total cycles from start to last accumulation latch:
  //   * stagger fill : (N-1) cycles
  //   * compute      :  N cycles of valid
  //   * pipeline drain (last product reaches PE[N-1][N-1]) : (N-1) cycles
  //   * +1 cycle for the accumulator output to settle after the last add
  //   = 3N-1
  //
  // We capture acc_out at cycle 3N-1 (count = 3*N-2 in 0-indexed terms,
  // since count starts at 0 when `start` was sampled).
  // ---------------------------------------------------------------------
  localparam int unsigned LAST_VALID_CYCLE  = 2*N - 2;   // last valid_west pulse
  localparam int unsigned CAPTURE_CYCLE     = 3*N - 1;   // acc settled

  typedef enum logic [1:0] {
    S_IDLE,
    S_RUN,
    S_LATCH,
    S_DONE
  } state_e;
  state_e state, next_state;

  logic [$clog2(3*N+4)-1:0] count;
  logic                     acc_clear_pulse;

  // a/b inject schedule:
  //   a_west[i] is A[i][k] when k == count - i  (so 0 <= k < N requires count >= i)
  //   b_north[j] is B[k][j] when k == count - j (so 0 <= k < N requires count >= j)
  //   valid_west[i] is high while a_west[i] is one of A[i][0..N-1].
  logic signed [DATA_W-1:0]   a_west   [N];
  logic signed [WEIGHT_W-1:0] b_north  [N];
  logic                       valid_w  [N];

  // Per-row/column injection schedule. Pulled out as separate signals so we
  // don't need block-local automatic variables (Icarus 2012 mode rejects
  // them).
  logic        a_active [N];
  logic        b_active [N];
  int          k_i      [N];
  int          k_j      [N];

  always_comb begin
    for (int i = 0; i < N; i++) begin
      a_active[i] = (count >= i) && (count < i + N) && (state == S_RUN);
      k_i[i]      = count - i;
      a_west[i]   = a_active[i] ? a_mat[i*N + k_i[i]] : '0;
      valid_w[i]  = a_active[i];
    end
    for (int j = 0; j < N; j++) begin
      b_active[j] = (count >= j) && (count < j + N) && (state == S_RUN);
      k_j[j]      = count - j;
      b_north[j]  = b_active[j] ? b_mat[k_j[j]*N + j] : '0;
    end
  end

  // -------- Array instance --------
  logic signed [ACC_W-1:0] acc_live [N][N];

  sa_top #(
    .N        (N),
    .DATA_W   (DATA_W),
    .WEIGHT_W (WEIGHT_W),
    .ACC_W    (ACC_W)
  ) u_array (
    .clk        (clk),
    .rst_n      (rst_n),
    .acc_clear  (acc_clear_pulse),
    .a_west     (a_west),
    .valid_west (valid_w),
    .b_north    (b_north),
    .acc_out    (acc_live)
  );

  // -------- Result latch --------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++)
          c_mat[i*N + j] <= '0;
    end else if (state == S_LATCH) begin
      for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++)
          c_mat[i*N + j] <= acc_live[i][j];
    end
  end

  // -------- FSM --------
  always_comb begin
    next_state      = state;
    acc_clear_pulse = 1'b0;
    busy            = (state != S_IDLE);
    done            = 1'b0;

    unique case (state)
      S_IDLE: begin
        if (start) begin
          next_state      = S_RUN;
          acc_clear_pulse = 1'b1;
        end
      end
      S_RUN: begin
        if (count == CAPTURE_CYCLE)
          next_state = S_LATCH;
      end
      S_LATCH: begin
        next_state = S_DONE;
      end
      S_DONE: begin
        done       = 1'b1;
        next_state = S_IDLE;
      end
      default: next_state = S_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      count <= '0;
    end else begin
      state <= next_state;
      if (state == S_IDLE && start)
        count <= '0;
      else if (state == S_RUN)
        count <= count + 1;
      else
        count <= count;
    end
  end

endmodule : sa_buffer

`default_nettype wire
