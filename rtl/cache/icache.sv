// =============================================================================
// icache.sv — L1 Instruction Cache for the SEDA SoC.
//
// Geometry (from cache_pkg):
//   * 4 KiB total, 32-byte lines, 128 sets, direct-mapped (1 way)
//   * Address breakdown: tag[31:12] | set[11:5] | word_off[4:2] | byte_off[1:0]
//
// Interface to CPU (matches imem_sync's contract + an imem_stall output):
//   * 1-cycle synchronous read on a hit: addr at cycle T -> rdata at cycle T+1
//   * On miss: stall=1 while the cache refills the line via an 8-beat AXI4-Full
//     INCR burst from backing memory. Once the line is filled, the next cycle
//     is a hit (stall=0) and rdata is registered the following cycle.
//
// Embedded AXI4-Full read master:
//   * ARID  = 0 (single outstanding refill — blocking miss handling)
//   * ARLEN = 7 (8 beats), ARSIZE = 2 (4 bytes), ARBURST = INCR
//
// Interaction with fetch.sv:
//   The cache's cpu_rdata register holds the last-hit data through a miss
//   (it only updates on hits). fetch.sv's held_instr_q captures this on the
//   first stall cycle — that captured value is the LAST valid response
//   before the miss, which is exactly the instruction the pipeline needs
//   next (the one immediately preceding the missed addr in stream order).
//   The missed instruction itself reaches IF/ID one cycle after stall drops,
//   via the normal imem_rdata path. No fetch.sv changes are required.
// =============================================================================
`default_nettype none

module icache
  import cache_pkg::*;
#(
  parameter int unsigned ID_W = 4
)(
  input  logic         clk,
  input  logic         rst_n,

  // CPU side (drop-in for imem_sync, plus stall)
  input  logic [31:0]  cpu_addr,
  input  logic         cpu_re,
  output logic [31:0]  cpu_rdata,
  output logic         cpu_stall,

  // AXI4-Full read master
  output logic [ID_W-1:0]  m_axi_arid,
  output logic [31:0]      m_axi_araddr,
  output logic [7:0]       m_axi_arlen,
  output logic [2:0]       m_axi_arsize,
  output logic [1:0]       m_axi_arburst,
  output logic             m_axi_arvalid,
  input  logic             m_axi_arready,

  input  logic [ID_W-1:0]  m_axi_rid,
  input  logic [31:0]      m_axi_rdata,
  input  logic [1:0]       m_axi_rresp,
  input  logic             m_axi_rlast,
  input  logic             m_axi_rvalid,
  output logic             m_axi_rready
);

  // ---------------------------------------------------------------------------
  // Address breakdown of the current CPU request
  // ---------------------------------------------------------------------------
  logic [TAG_BITS-1:0]      req_tag;
  logic [SET_IDX_BITS-1:0]  req_set;
  logic [WORD_OFF_BITS-1:0] req_word_off;

  assign req_tag      = cpu_addr[TAG_HI:TAG_LO];
  assign req_set      = cpu_addr[SET_IDX_HI:SET_IDX_LO];
  assign req_word_off = cpu_addr[WORD_OFF_HI:WORD_OFF_LO];

  // ---------------------------------------------------------------------------
  // Tag + valid arrays (synthesisable to BRAM in Phase 7)
  // ---------------------------------------------------------------------------
  logic [TAG_BITS-1:0] tag_array   [0:NUM_SETS-1];
  logic                valid_array [0:NUM_SETS-1];

  // ---------------------------------------------------------------------------
  // Data array — flattened to a single 32-bit-word array indexed by
  // {set, word_off} to keep Icarus's VPI happy (it dislikes packed multi-D).
  // ---------------------------------------------------------------------------
  logic [31:0] data_array [0:NUM_SETS*LINE_WORDS-1];

  function automatic int unsigned data_idx(input logic [SET_IDX_BITS-1:0] s,
                                           input logic [WORD_OFF_BITS-1:0] w);
    return (int'(s) * LINE_WORDS) + int'(w);
  endfunction

  // ---------------------------------------------------------------------------
  // Hit / miss
  // ---------------------------------------------------------------------------
  logic hit;
  assign hit = valid_array[req_set] && (tag_array[req_set] == req_tag);

  // ---------------------------------------------------------------------------
  // FSM
  //   S_IDLE   : serve hits; on miss, transition to S_AR
  //   S_AR     : drive AR channel; on arready handshake, transition to S_REFILL
  //   S_REFILL : capture R beats; on RLAST, write tag+valid, return to IDLE
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] { S_IDLE, S_AR, S_REFILL } state_e;

  state_e state_q;

  logic [SET_IDX_BITS-1:0]  refill_set_q;
  logic [TAG_BITS-1:0]      refill_tag_q;
  logic [WORD_OFF_BITS-1:0] beat_idx_q;

  // line-aligned refill base address (clears word_off and byte_off)
  logic [31:0] refill_addr_w;
  assign refill_addr_w = {refill_tag_q, refill_set_q,
                          {(WORD_OFF_BITS+BYTE_OFF_BITS){1'b0}}};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q      <= S_IDLE;
      refill_set_q <= '0;
      refill_tag_q <= '0;
      beat_idx_q   <= '0;
      // Invalidate every line on reset.
      for (int i = 0; i < NUM_SETS; i++) begin
        valid_array[i] <= 1'b0;
      end
    end else begin
      unique case (state_q)
        S_IDLE: begin
          if (cpu_re && !hit) begin
            refill_set_q <= req_set;
            refill_tag_q <= req_tag;
            beat_idx_q   <= '0;
            state_q      <= S_AR;
          end
        end
        S_AR: begin
          if (m_axi_arready) state_q <= S_REFILL;
        end
        S_REFILL: begin
          if (m_axi_rvalid) begin
            data_array[data_idx(refill_set_q, beat_idx_q)] <= m_axi_rdata;
            if (m_axi_rlast) begin
              tag_array[refill_set_q]   <= refill_tag_q;
              valid_array[refill_set_q] <= 1'b1;
              state_q <= S_IDLE;
            end else begin
              beat_idx_q <= beat_idx_q + 1'b1;
            end
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // CPU rdata register — 1-cycle latent on a hit (matches imem_sync). Holds
  // the last-hit value during miss/refill (NEVER updated mid-refill).
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_rdata <= 32'h0000_0013;   // NOP-ish on reset
    end else if (state_q == S_IDLE && cpu_re && hit) begin
      cpu_rdata <= data_array[data_idx(req_set, req_word_off)];
    end
  end

  // ---------------------------------------------------------------------------
  // Stall: any time we cannot satisfy a request this cycle.
  //   * IDLE + miss  -> stall=1 (will start refill next cycle)
  //   * AR / REFILL  -> stall=1 always
  //   * IDLE + hit   -> stall=0 (rdata appears next cycle, contract met)
  //   * IDLE + !cpu_re -> stall=0 (no request)
  // ---------------------------------------------------------------------------
  assign cpu_stall = (state_q != S_IDLE) || (cpu_re && !hit);

  // ---------------------------------------------------------------------------
  // AXI master outputs
  // ---------------------------------------------------------------------------
  assign m_axi_arid    = '0;
  assign m_axi_araddr  = refill_addr_w;
  assign m_axi_arlen   = AXI_BURST_LEN;
  assign m_axi_arsize  = AXI_BURST_SIZE;
  assign m_axi_arburst = AXI_BURST_INCR;
  assign m_axi_arvalid = (state_q == S_AR);
  assign m_axi_rready  = (state_q == S_REFILL);

endmodule : icache

`default_nettype wire
