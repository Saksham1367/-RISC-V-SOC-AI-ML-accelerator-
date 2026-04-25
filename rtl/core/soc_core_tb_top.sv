// =============================================================================
// soc_core_tb_top.sv — Phase-1 testbench harness for the RISC-V core.
//
// Wraps the core with synchronous IMEM and a single-cycle DMEM SRAM. The
// cocotb test loads .hex programs into both via $readmemh through the
// IMEM_INIT / DMEM_INIT plus-args, then runs the core for N cycles and
// inspects state via hierarchical references.
//
// This is the top-level for the core integration test.
// =============================================================================
`default_nettype none

module soc_core_tb_top #(
  parameter int unsigned IMEM_DEPTH = 4096,
  parameter int unsigned DMEM_DEPTH = 4096
)(
  input  logic clk,
  input  logic rst_n
);

  // -------- IMEM --------
  logic [31:0] imem_addr;
  logic        imem_re;
  logic [31:0] imem_rdata;

  // -------- DMEM --------
  logic [31:0] dmem_addr;
  logic [31:0] dmem_wdata;
  logic [3:0]  dmem_wstrb;
  logic        dmem_re;
  logic        dmem_we;
  logic [31:0] dmem_rdata;

  // -------- Core --------
  riscv_core #(.RESET_PC(32'h0)) u_core (
    .clk        (clk),
    .rst_n      (rst_n),
    .imem_addr  (imem_addr),
    .imem_re    (imem_re),
    .imem_rdata (imem_rdata),
    .dmem_addr  (dmem_addr),
    .dmem_wdata (dmem_wdata),
    .dmem_wstrb (dmem_wstrb),
    .dmem_re    (dmem_re),
    .dmem_we    (dmem_we),
    .dmem_rdata (dmem_rdata)
  );

  // 1-cycle latency IMEM
  imem_sync #(.DEPTH_WORDS(IMEM_DEPTH)) u_imem (
    .clk   (clk),
    .addr  (imem_addr),
    .re    (imem_re),
    .rdata (imem_rdata)
  );

  // Combinational-read DMEM (matches what execute.sv expects for load_align)
  sram #(.DEPTH_WORDS(DMEM_DEPTH)) u_dmem (
    .clk   (clk),
    .addr  (dmem_addr),
    .re    (dmem_re),
    .we    (dmem_we),
    .wstrb (dmem_wstrb),
    .wdata (dmem_wdata),
    .rdata (dmem_rdata)
  );

  // ---------------------------------------------------------------------
  // Plus-arg image loaders for cocotb / iverilog
  // +IMEM=path/to/program.hex
  // +DMEM=path/to/initial_data.hex
  // ---------------------------------------------------------------------
  string imem_path;
  string dmem_path;

  initial begin
    if ($value$plusargs("IMEM=%s", imem_path)) begin
      $display("[TB] Loading IMEM image: %s", imem_path);
      $readmemh(imem_path, u_imem.u_sram.mem);
    end
    if ($value$plusargs("DMEM=%s", dmem_path)) begin
      $display("[TB] Loading DMEM image: %s", dmem_path);
      $readmemh(dmem_path, u_dmem.mem);
    end
  end

  // VCD dump for waveform inspection (cocotb usually adds its own; this is a
  // belt-and-suspenders for direct vvp invocations).
  initial begin
    if ($test$plusargs("DUMP")) begin
      $dumpfile("dump.vcd");
      $dumpvars(0, soc_core_tb_top);
    end
  end

endmodule : soc_core_tb_top

`default_nettype wire
