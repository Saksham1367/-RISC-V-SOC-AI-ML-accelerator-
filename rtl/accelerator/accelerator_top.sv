// =============================================================================
// accelerator_top.sv — Systolic array accelerator wrapped in an AXI4-Lite slave.
//
// Memory map (offsets from the AXI4-Lite base, all 32-bit words):
//
//   reg idx | offset  | name              | access | description
//   --------|---------|-------------------|--------|-----------------------------
//   0       | 0x000   | CTRL              | RW     | [0]=start (W1S; auto-clear)
//   1       | 0x004   | STATUS            | R      | [0]=busy, [1]=done
//   2       | 0x008   | MATRIX_SIZE       | RW     | reserved (always 4x4 in v1)
//   3       | 0x00C   | reserved          |        |
//   4..7    | 0x010-1F| A_ROW0..3         | RW     | A row i = 4 packed INT8 in word i (LSB=col 0)
//   8..11   | 0x020-2F| B_ROW0..3         | RW     | B row i = 4 packed INT8 (LSB=col 0)
//   12..27  | 0x030-6F| C[i*4 + j] (INT32)| R      | result element row-major
//
// Total register count = 28 (rounded up to 32 in the slave for power-of-two
// addressing).
// =============================================================================
`default_nettype none

module accelerator_top
  import sa_pkg::*;
#(
  parameter int unsigned ADDR_W = 32,
  parameter int unsigned DATA_W = 32,
  parameter int unsigned N      = sa_pkg::ARRAY_N
)(
  input  logic                clk,
  input  logic                rst_n,

  // AXI4-Lite slave port
  input  logic [ADDR_W-1:0]   s_axi_awaddr,
  input  logic                s_axi_awvalid,
  output logic                s_axi_awready,
  input  logic [DATA_W-1:0]   s_axi_wdata,
  input  logic [DATA_W/8-1:0] s_axi_wstrb,
  input  logic                s_axi_wvalid,
  output logic                s_axi_wready,
  output logic [1:0]          s_axi_bresp,
  output logic                s_axi_bvalid,
  input  logic                s_axi_bready,
  input  logic [ADDR_W-1:0]   s_axi_araddr,
  input  logic                s_axi_arvalid,
  output logic                s_axi_arready,
  output logic [DATA_W-1:0]   s_axi_rdata,
  output logic [1:0]          s_axi_rresp,
  output logic                s_axi_rvalid,
  input  logic                s_axi_rready
);

  localparam int unsigned NUM_REGS = 32;

  // -------- AXI4-Lite register bank --------
  logic [NUM_REGS-1:0]      writable_mask;
  logic [DATA_W-1:0]        csr_in    [NUM_REGS];
  logic [DATA_W-1:0]        csr_q     [NUM_REGS];
  logic                     csr_write [NUM_REGS];

  // CTRL(0), MATRIX_SIZE(2), A rows (4..7), B rows (8..11) are RW.
  // STATUS(1), reserved(3), C words (12..27), trailing (28..31) are R/O.
  always_comb begin
    writable_mask = '0;
    writable_mask[0] = 1'b1;       // CTRL
    writable_mask[2] = 1'b1;       // MATRIX_SIZE
    for (int i = 4; i <= 11; i++) begin
      writable_mask[i] = 1'b1;     // A/B operand rows
    end
  end

  axi4_lite_slave #(
    .NUM_REGS (NUM_REGS),
    .ADDR_W   (ADDR_W),
    .DATA_W   (DATA_W)
  ) u_axil (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .writable_mask (writable_mask),
    .csr_in        (csr_in),
    .csr_q         (csr_q),
    .csr_write     (csr_write)
  );

  // -------- Decode operand registers --------
  logic signed [7:0] a_mat_flat [N*N];
  logic signed [7:0] b_mat_flat [N*N];
  logic signed [31:0] c_mat_flat [N*N];

  for (genvar i = 0; i < N; i++) begin : g_unpack
    for (genvar j = 0; j < N; j++) begin : g_col
      assign a_mat_flat[i*N + j] = csr_q[4 + i][j*8 +: 8];
      assign b_mat_flat[i*N + j] = csr_q[8 + i][j*8 +: 8];
    end
  end

  // -------- Drive accelerator --------
  logic start_pulse;
  logic acc_busy;
  logic acc_done;

  // Start when host writes a 1 to CTRL[0]. Auto-clear is handled by the
  // CSR read-only echo: after the FSM has consumed `start`, the CTRL[0] bit
  // is logically irrelevant; we keep it RW for simplicity but pulse start
  // only on the cycle of the write.
  assign start_pulse = csr_write[0] & csr_q[0][0];

  sa_buffer #(
    .N (N)
  ) u_sa (
    .clk   (clk),
    .rst_n (rst_n),
    .a_mat (a_mat_flat),
    .b_mat (b_mat_flat),
    .start (start_pulse),
    .busy  (acc_busy),
    .done  (acc_done),
    .c_mat (c_mat_flat)
  );

  // -------- Drive read-only CSRs --------
  logic done_sticky_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)              done_sticky_q <= 1'b0;
    else if (start_pulse)    done_sticky_q <= 1'b0;   // clear on new run
    else if (acc_done)       done_sticky_q <= 1'b1;
  end

  always_comb begin
    for (int i = 0; i < NUM_REGS; i++) csr_in[i] = '0;
    // STATUS
    csr_in[1][0] = acc_busy;
    csr_in[1][1] = done_sticky_q;
    // C[i][j] -> reg 12 + i*N + j
    for (int i = 0; i < N; i++) begin
      for (int j = 0; j < N; j++) begin
        csr_in[12 + i*N + j] = c_mat_flat[i*N + j];
      end
    end
  end

endmodule : accelerator_top

`default_nettype wire
