// =============================================================================
// pe.sv — Single Processing Element (PE) for the systolic array.
//
// Weight-Stationary dataflow:
//   * load_weight pulse latches weight_in into the PE's weight register.
//   * In compute mode (valid_in asserted), each cycle:
//         partial   = data_in * weight
//         acc       = acc + partial
//         data_out  = data_in (passed east, registered)
//         valid_out = valid_in (registered)
//
// All inputs are signed (INT8 × INT8 → INT16 → INT32 accumulate).
// =============================================================================
`default_nettype none

module pe
  import sa_pkg::*;
#(
  parameter int unsigned DATA_W   = sa_pkg::DATA_W,
  parameter int unsigned WEIGHT_W = sa_pkg::WEIGHT_W,
  parameter int unsigned ACC_W    = sa_pkg::ACC_W
)(
  input  logic                       clk,
  input  logic                       rst_n,

  // Configuration
  input  logic                       load_weight,    // pulse: capture weight_in
  input  logic signed [WEIGHT_W-1:0] weight_in,
  input  logic                       acc_clear,      // sync clear of accumulator

  // Streaming inputs
  input  logic signed [DATA_W-1:0]   data_in,
  input  logic                       valid_in,

  // Streaming outputs (registered, propagated east)
  output logic signed [DATA_W-1:0]   data_out,
  output logic                       valid_out,

  // Accumulator output
  output logic signed [ACC_W-1:0]    acc_out
);

  logic signed [WEIGHT_W-1:0]      weight_q;
  logic signed [ACC_W-1:0]         acc_q;
  logic signed [DATA_W+WEIGHT_W-1:0] product;

  assign product = data_in * weight_q;

  // Weight register
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)            weight_q <= '0;
    else if (load_weight)  weight_q <= weight_in;
  end

  // Accumulator
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      acc_q <= '0;
    else if (acc_clear)
      acc_q <= '0;
    else if (valid_in)
      acc_q <= acc_q + ACC_W'(product);  // sign-extend product to ACC_W
  end

  // Eastward pass-through (registered, so all PEs in a row stay in lockstep)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_out  <= '0;
      valid_out <= 1'b0;
    end else begin
      data_out  <= data_in;
      valid_out <= valid_in;
    end
  end

  assign acc_out = acc_q;

endmodule : pe

`default_nettype wire
