// =============================================================================
// axi4_lite_slave.sv — AXI4-Lite slave with a small parameterised register bank.
//
// Implements the standard 5 AXI4-Lite channels (AW, W, B, AR, R) for a 32-bit
// data / 32-bit address slave with:
//   * Full handshake (VALID / READY)
//   * Decoupled write address + data acceptance (with one-deep buffering)
//   * Single-cycle response on hits; OKAY responses always (no SLVERR)
//
// CSR map (parameterised):
//   * NUM_REGS 32-bit registers, address = base + 4*idx (low 2 bits ignored)
//   * Write strobes are honoured per byte (wstrb)
//   * Some registers are "host writable" (RW), others are "host read-only" (R/O)
//     status registers driven by the rest of the design. These two types are
//     separated by the writable_mask parameter.
//
// Hooks:
//   * `csr_q[]`     — current value of every register (read by external logic)
//   * `csr_write[]` — pulsed for one cycle when the host writes that register
//   * `csr_in[]`    — value injected into a read-only register by the design
//                      (only meaningful for bits where writable_mask[i]=0)
// =============================================================================
`default_nettype none

module axi4_lite_slave #(
  parameter int unsigned NUM_REGS = 32,
  parameter int unsigned ADDR_W   = 32,
  parameter int unsigned DATA_W   = 32
)(
  input  logic                          clk,
  input  logic                          rst_n,

  // ----- AXI4-Lite slave port -----
  // Write address channel
  input  logic [ADDR_W-1:0]             s_axi_awaddr,
  input  logic                          s_axi_awvalid,
  output logic                          s_axi_awready,
  // Write data channel
  input  logic [DATA_W-1:0]             s_axi_wdata,
  input  logic [DATA_W/8-1:0]           s_axi_wstrb,
  input  logic                          s_axi_wvalid,
  output logic                          s_axi_wready,
  // Write response channel
  output logic [1:0]                    s_axi_bresp,
  output logic                          s_axi_bvalid,
  input  logic                          s_axi_bready,
  // Read address channel
  input  logic [ADDR_W-1:0]             s_axi_araddr,
  input  logic                          s_axi_arvalid,
  output logic                          s_axi_arready,
  // Read data channel
  output logic [DATA_W-1:0]             s_axi_rdata,
  output logic [1:0]                    s_axi_rresp,
  output logic                          s_axi_rvalid,
  input  logic                          s_axi_rready,

  // ----- Register bank hooks -----
  // 1 bit per register: 1 = host writable (W from AXI takes effect),
  //                     0 = read-only (writes ignored, value driven by csr_in)
  input  logic [NUM_REGS-1:0]           writable_mask,
  // External value for read-only registers
  input  logic [DATA_W-1:0]             csr_in   [NUM_REGS],
  // Current value of every register (combinational view)
  output logic [DATA_W-1:0]             csr_q    [NUM_REGS],
  // One-cycle pulse when host writes that register (used to e.g. trigger 'start')
  output logic                          csr_write[NUM_REGS]
);

  // ---------------------------------------------------------------------
  // Storage for writable registers
  // ---------------------------------------------------------------------
  logic [DATA_W-1:0] csr_storage [NUM_REGS];

  // ---------------------------------------------------------------------
  // Address decode helper
  // ---------------------------------------------------------------------
  function automatic int reg_index(input logic [ADDR_W-1:0] addr);
    reg_index = int'(addr[$clog2(NUM_REGS)+1:2]);
  endfunction

  // ---------------------------------------------------------------------
  // Write channel — accept AW and W independently, then issue B.
  // ---------------------------------------------------------------------
  logic [ADDR_W-1:0] aw_addr_q;
  logic              aw_pending_q;
  logic [DATA_W-1:0] w_data_q;
  logic [DATA_W/8-1:0] w_strb_q;
  logic              w_pending_q;
  logic              b_pending_q;

  assign s_axi_awready = ~aw_pending_q;
  assign s_axi_wready  = ~w_pending_q;
  assign s_axi_bvalid  = b_pending_q;
  assign s_axi_bresp   = 2'b00;  // OKAY

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_addr_q    <= '0;
      aw_pending_q <= 1'b0;
      w_data_q     <= '0;
      w_strb_q     <= '0;
      w_pending_q  <= 1'b0;
      b_pending_q  <= 1'b0;
      for (int i = 0; i < NUM_REGS; i++) csr_storage[i] <= '0;
    end else begin
      // Latch AW
      if (s_axi_awvalid && s_axi_awready) begin
        aw_addr_q    <= s_axi_awaddr;
        aw_pending_q <= 1'b1;
      end
      // Latch W
      if (s_axi_wvalid && s_axi_wready) begin
        w_data_q    <= s_axi_wdata;
        w_strb_q    <= s_axi_wstrb;
        w_pending_q <= 1'b1;
      end
      // Commit when both AW and W have been latched and B not blocked
      if (aw_pending_q && w_pending_q && !b_pending_q) begin
        // perform the write
        if (writable_mask[reg_index(aw_addr_q)]) begin
          for (int b = 0; b < DATA_W/8; b++) begin
            if (w_strb_q[b]) begin
              csr_storage[reg_index(aw_addr_q)][b*8 +: 8] <= w_data_q[b*8 +: 8];
            end
          end
        end
        aw_pending_q <= 1'b0;
        w_pending_q  <= 1'b0;
        b_pending_q  <= 1'b1;
      end
      // Retire B
      if (b_pending_q && s_axi_bready) begin
        b_pending_q <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Read channel — single-cycle response on accepted AR.
  // ---------------------------------------------------------------------
  logic [DATA_W-1:0] r_data_q;
  logic              r_valid_q;

  assign s_axi_arready = ~r_valid_q;
  assign s_axi_rdata   = r_data_q;
  assign s_axi_rresp   = 2'b00;
  assign s_axi_rvalid  = r_valid_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_data_q  <= '0;
      r_valid_q <= 1'b0;
    end else begin
      if (s_axi_arvalid && s_axi_arready) begin
        r_data_q  <= csr_q[reg_index(s_axi_araddr)];
        r_valid_q <= 1'b1;
      end else if (r_valid_q && s_axi_rready) begin
        r_valid_q <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------
  // CSR view + write pulses
  // ---------------------------------------------------------------------
  for (genvar i = 0; i < NUM_REGS; i++) begin : g_csr_view
    assign csr_q[i] = writable_mask[i] ? csr_storage[i] : csr_in[i];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NUM_REGS; i++) csr_write[i] <= 1'b0;
    end else begin
      for (int i = 0; i < NUM_REGS; i++) csr_write[i] <= 1'b0;
      if (aw_pending_q && w_pending_q && !b_pending_q) begin
        csr_write[reg_index(aw_addr_q)] <= 1'b1;
      end
    end
  end

endmodule : axi4_lite_slave

`default_nettype wire
