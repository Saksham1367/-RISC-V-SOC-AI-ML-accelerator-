// =============================================================================
// axi4_full_slave_sram.sv — AXI4-Full slave wrapping a backing SRAM.
//
// Supports INCR read AND write bursts (any length up to AXLEN+1 = 256 beats).
// Designed to serve both the L1 I-cache (read-only, 8-beat refills) and the
// L1 D-cache (read 8-beat refills + write 8-beat or single-beat to memory).
//
// Memory model:
//   * Internal SRAM with byte-strobe synchronous write, combinational read
//     (matches the existing rtl/memory/sram.sv module). Word-addressed
//     internally; the AXI master must drive 4-byte-aligned addresses
//     (ARSIZE / AWSIZE = 2).
//
// FSM:
//   READ:  S_AR -> S_R(*N beats) -> S_AR
//   WRITE: S_AW -> S_W(*N beats) -> S_B -> S_AW
//
// We arbitrate read vs write at the top level: both are independent channels
// and AXI4 allows them to be in flight concurrently. For Phase 2a's I-cache
// (read-only), the write side is idle. The write FSM is fully functional but
// ignored unless an AW transaction comes in.
//
// Out-of-order is NOT supported: ARID is echoed in RID but a single read
// transaction is processed at a time. Same for writes.
// =============================================================================
`default_nettype none

module axi4_full_slave_sram
  import cache_pkg::*;
#(
  parameter int unsigned ADDR_W       = 32,
  parameter int unsigned DATA_W       = 32,
  parameter int unsigned ID_W         = 4,
  parameter int unsigned DEPTH_WORDS  = 4096      // 16 KB
)(
  input  logic                clk,
  input  logic                rst_n,

  // ----- AXI4-Full slave: AR / R channels (read) -----
  input  logic [ID_W-1:0]     s_axi_arid,
  input  logic [ADDR_W-1:0]   s_axi_araddr,
  input  logic [7:0]          s_axi_arlen,
  input  logic [2:0]          s_axi_arsize,
  input  logic [1:0]          s_axi_arburst,
  input  logic                s_axi_arvalid,
  output logic                s_axi_arready,

  output logic [ID_W-1:0]     s_axi_rid,
  output logic [DATA_W-1:0]   s_axi_rdata,
  output logic [1:0]          s_axi_rresp,
  output logic                s_axi_rlast,
  output logic                s_axi_rvalid,
  input  logic                s_axi_rready,

  // ----- AXI4-Full slave: AW / W / B channels (write) -----
  input  logic [ID_W-1:0]     s_axi_awid,
  input  logic [ADDR_W-1:0]   s_axi_awaddr,
  input  logic [7:0]          s_axi_awlen,
  input  logic [2:0]          s_axi_awsize,
  input  logic [1:0]          s_axi_awburst,
  input  logic                s_axi_awvalid,
  output logic                s_axi_awready,

  input  logic [DATA_W-1:0]   s_axi_wdata,
  input  logic [DATA_W/8-1:0] s_axi_wstrb,
  input  logic                s_axi_wlast,
  input  logic                s_axi_wvalid,
  output logic                s_axi_wready,

  output logic [ID_W-1:0]     s_axi_bid,
  output logic [1:0]          s_axi_bresp,
  output logic                s_axi_bvalid,
  input  logic                s_axi_bready
);

  localparam int unsigned WORD_ADDR_W = $clog2(DEPTH_WORDS);

  // ===========================================================================
  // Backing SRAM (byte-strobe sync write, comb read). Same shape as
  // rtl/memory/sram.sv, instantiated here so the test bench can poke
  // initial contents via the canonical hierarchical path
  // dut.u_sram.mem[word_idx].
  // ===========================================================================
  logic [DATA_W-1:0] sram_rdata;
  logic              sram_we;
  logic [DATA_W/8-1:0] sram_wstrb;
  logic [ADDR_W-1:0] sram_addr;
  logic [DATA_W-1:0] sram_wdata;

  sram #(.DEPTH_WORDS(DEPTH_WORDS)) u_sram (
    .clk   (clk),
    .addr  (sram_addr),
    .re    (1'b1),
    .we    (sram_we),
    .wstrb (sram_wstrb),
    .wdata (sram_wdata),
    .rdata (sram_rdata)
  );

  // ===========================================================================
  // Read FSM
  // ===========================================================================
  typedef enum logic [0:0] { R_IDLE, R_BEAT } r_state_e;

  r_state_e            r_state;
  logic [ADDR_W-1:0]   r_addr_q;       // current beat byte address
  logic [7:0]          r_beats_left;   // beats remaining (0 = last)
  logic [ID_W-1:0]     r_id_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_state      <= R_IDLE;
      r_addr_q     <= '0;
      r_beats_left <= '0;
      r_id_q       <= '0;
    end else begin
      unique case (r_state)
        R_IDLE: begin
          if (s_axi_arvalid && s_axi_arready) begin
            r_addr_q     <= s_axi_araddr;
            r_beats_left <= s_axi_arlen;
            r_id_q       <= s_axi_arid;
            r_state      <= R_BEAT;
          end
        end
        R_BEAT: begin
          if (s_axi_rvalid && s_axi_rready) begin
            if (r_beats_left == 8'd0) begin
              r_state <= R_IDLE;
            end else begin
              r_addr_q     <= r_addr_q + 32'd4;   // INCR, 4-byte beat
              r_beats_left <= r_beats_left - 8'd1;
            end
          end
        end
      endcase
    end
  end

  assign s_axi_arready = (r_state == R_IDLE);
  assign s_axi_rvalid  = (r_state == R_BEAT);
  assign s_axi_rid     = r_id_q;
  assign s_axi_rresp   = 2'b00;          // OKAY
  assign s_axi_rlast   = (r_state == R_BEAT) && (r_beats_left == 8'd0);

  // ===========================================================================
  // Write FSM
  // ===========================================================================
  typedef enum logic [1:0] { W_IDLE, W_BEAT, W_RESP } w_state_e;

  w_state_e            w_state;
  logic [ADDR_W-1:0]   w_addr_q;
  logic [7:0]          w_beats_left;
  logic [ID_W-1:0]     w_id_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_state      <= W_IDLE;
      w_addr_q     <= '0;
      w_beats_left <= '0;
      w_id_q       <= '0;
    end else begin
      unique case (w_state)
        W_IDLE: begin
          if (s_axi_awvalid && s_axi_awready) begin
            w_addr_q     <= s_axi_awaddr;
            w_beats_left <= s_axi_awlen;
            w_id_q       <= s_axi_awid;
            w_state      <= W_BEAT;
          end
        end
        W_BEAT: begin
          if (s_axi_wvalid && s_axi_wready) begin
            if (s_axi_wlast) begin
              w_state <= W_RESP;
            end else begin
              w_addr_q     <= w_addr_q + 32'd4;
              w_beats_left <= w_beats_left - 8'd1;
            end
          end
        end
        W_RESP: begin
          if (s_axi_bvalid && s_axi_bready) w_state <= W_IDLE;
        end
        default: w_state <= W_IDLE;
      endcase
    end
  end

  assign s_axi_awready = (w_state == W_IDLE);
  assign s_axi_wready  = (w_state == W_BEAT);
  assign s_axi_bvalid  = (w_state == W_RESP);
  assign s_axi_bid     = w_id_q;
  assign s_axi_bresp   = 2'b00;        // OKAY

  // ===========================================================================
  // SRAM driver — read has priority for combinational rdata; write happens
  // synchronously, so we can mux addr based on which side is active.
  // ===========================================================================
  always_comb begin
    sram_we    = 1'b0;
    sram_wstrb = '0;
    sram_wdata = '0;
    sram_addr  = '0;

    if (w_state == W_BEAT && s_axi_wvalid) begin
      sram_we    = 1'b1;
      sram_wstrb = s_axi_wstrb;
      sram_wdata = s_axi_wdata;
      sram_addr  = w_addr_q;
    end else if (r_state == R_BEAT) begin
      sram_addr  = r_addr_q;
    end
  end

  assign s_axi_rdata = sram_rdata;

endmodule : axi4_full_slave_sram

`default_nettype wire
