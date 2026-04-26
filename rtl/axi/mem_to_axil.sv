// =============================================================================
// mem_to_axil.sv — Bridges the RISC-V core's simple memory interface to AXI4-Lite.
//
// Protocol:
//   * CPU asserts req_valid for as many cycles as the load/store remains in EX.
//   * The bridge raises req_stall the moment it accepts the request and keeps
//     it high until the AXI4-Lite handshake has completed and the result has
//     been driven on req_rdata for one cycle. After that, the bridge enters a
//     S_DONE drain state, lowers req_stall, and waits for the CPU's req_valid
//     to fall (which it does as soon as the CPU advances past the load/store)
//     before returning to S_IDLE and accepting a new request.
// =============================================================================
`default_nettype none

module mem_to_axil #(
  parameter int unsigned ADDR_W = 32,
  parameter int unsigned DATA_W = 32
)(
  input  logic                clk,
  input  logic                rst_n,

  // CPU-side simple memory interface
  input  logic                req_valid,
  input  logic                req_we,
  input  logic [ADDR_W-1:0]   req_addr,
  input  logic [DATA_W-1:0]   req_wdata,
  input  logic [DATA_W/8-1:0] req_wstrb,
  output logic                req_stall,
  output logic [DATA_W-1:0]   req_rdata,
  output logic                req_rvalid,

  // AXI4-Lite master port
  output logic [ADDR_W-1:0]   m_axi_awaddr,
  output logic                m_axi_awvalid,
  input  logic                m_axi_awready,
  output logic [DATA_W-1:0]   m_axi_wdata,
  output logic [DATA_W/8-1:0] m_axi_wstrb,
  output logic                m_axi_wvalid,
  input  logic                m_axi_wready,
  input  logic [1:0]          m_axi_bresp,
  input  logic                m_axi_bvalid,
  output logic                m_axi_bready,
  output logic [ADDR_W-1:0]   m_axi_araddr,
  output logic                m_axi_arvalid,
  input  logic                m_axi_arready,
  input  logic [DATA_W-1:0]   m_axi_rdata,
  input  logic [1:0]          m_axi_rresp,
  input  logic                m_axi_rvalid,
  output logic                m_axi_rready
);

  typedef enum logic [2:0] {
    S_IDLE,
    S_WR_ADDR_DATA,
    S_WR_RESP,
    S_RD_ADDR,
    S_RD_DATA,
    S_DONE             // hold one cycle so CPU sees stall=0 + valid rdata
  } state_e;
  state_e st, st_next;

  logic        aw_done, w_done;
  logic [ADDR_W-1:0]   addr_q;
  logic [DATA_W-1:0]   wdata_q;
  logic [DATA_W/8-1:0] wstrb_q;
  logic [DATA_W-1:0]   rdata_q;

  // Track whether the request currently in IDLE has been seen.
  // We don't strictly need this since S_DONE handles drain, but it makes the
  // intent explicit.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st       <= S_IDLE;
      addr_q   <= '0;
      wdata_q  <= '0;
      wstrb_q  <= '0;
      aw_done  <= 1'b0;
      w_done   <= 1'b0;
      rdata_q  <= '0;
    end else begin
      st <= st_next;

      // Latch new request when leaving IDLE
      if (st == S_IDLE && req_valid) begin
        addr_q  <= req_addr;
        wdata_q <= req_wdata;
        wstrb_q <= req_wstrb;
        aw_done <= 1'b0;
        w_done  <= 1'b0;
      end

      // Track AW / W handshakes
      if (st == S_WR_ADDR_DATA) begin
        if (m_axi_awvalid && m_axi_awready) aw_done <= 1'b1;
        if (m_axi_wvalid  && m_axi_wready)  w_done  <= 1'b1;
      end

      // Capture R data
      if (st == S_RD_DATA && m_axi_rvalid) begin
        rdata_q <= m_axi_rdata;
      end
    end
  end

  // Combinational helpers
  logic aw_ok_now, w_ok_now;
  assign aw_ok_now = aw_done | (m_axi_awvalid & m_axi_awready);
  assign w_ok_now  = w_done  | (m_axi_wvalid  & m_axi_wready);

  // FSM next-state
  always_comb begin
    st_next = st;
    unique case (st)
      S_IDLE: begin
        if (req_valid) begin
          if (req_we) st_next = S_WR_ADDR_DATA;
          else        st_next = S_RD_ADDR;
        end
      end
      S_WR_ADDR_DATA: begin
        if (aw_ok_now && w_ok_now)            st_next = S_WR_RESP;
      end
      S_WR_RESP: begin
        if (m_axi_bvalid)                     st_next = S_DONE;
      end
      S_RD_ADDR: begin
        if (m_axi_arvalid && m_axi_arready)   st_next = S_RD_DATA;
      end
      S_RD_DATA: begin
        if (m_axi_rvalid)                     st_next = S_DONE;
      end
      S_DONE: begin
        // One cycle for the CPU to sample rdata_q with stall=0 and advance.
        if (!req_valid)                       st_next = S_IDLE;
        // If req_valid is somehow still high (CPU not advancing yet), stay here
        // — this shouldn't happen because mem_stall=0 in S_DONE permits the EX
        // stage to commit and the next instruction to enter, dropping req_valid.
        else                                  st_next = S_IDLE;
      end
      default:                                st_next = S_IDLE;
    endcase
  end

  // AXI master outputs
  assign m_axi_awaddr  = addr_q;
  assign m_axi_awvalid = (st == S_WR_ADDR_DATA) && !aw_done;
  assign m_axi_wdata   = wdata_q;
  assign m_axi_wstrb   = wstrb_q;
  assign m_axi_wvalid  = (st == S_WR_ADDR_DATA) && !w_done;
  assign m_axi_bready  = (st == S_WR_RESP);
  assign m_axi_araddr  = addr_q;
  assign m_axi_arvalid = (st == S_RD_ADDR);
  assign m_axi_rready  = (st == S_RD_DATA);

  // CPU side
  // Stall while busy — but NOT during S_DONE (so CPU completes writeback).
  // Also stall on the very first cycle a new request arrives in IDLE, to
  // prevent the CPU from completing the load with stale rdata_q before the
  // bridge has even started the transaction.
  assign req_stall  = (st != S_IDLE && st != S_DONE)
                    | (st == S_IDLE && req_valid);
  assign req_rdata  = rdata_q;
  assign req_rvalid = (st == S_DONE);

endmodule : mem_to_axil

`default_nettype wire
