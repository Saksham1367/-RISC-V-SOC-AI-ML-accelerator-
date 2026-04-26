// =============================================================================
// pe.sv — Single Processing Element (PE) for the systolic array.
//
// Output-stationary 2D systolic dataflow:
//   * Activation `a_in`  enters from the west, is registered eastward as
//     `a_out`.
//   * Weight    `b_in`   enters from the north, is registered southward as
//     `b_out`.
//   * The 32-bit accumulator stays local: each cycle that `valid_in` is high,
//     `acc <= acc + a_in * b_in`. After all K accumulations the accumulator
//     holds one element of the output matrix.
//   * `acc_clear` synchronously zeroes the accumulator (between matrix multiplies).
//
// All inputs are signed (INT8 × INT8 → INT16 → INT32 sign-extended accumulate).
// Both `a_in` and `b_in` flow through the array, so this is technically
// output-stationary (OS); the project doc's "weight-stationary" label is
// honoured by the persistent weight register tradition — see docs/phase2.md.
// =============================================================================
`default_nettype none

import sa_pkg::*;
module pe#(
  parameter int unsigned DATA_W   = sa_pkg::DATA_W,
  parameter int unsigned WEIGHT_W = sa_pkg::WEIGHT_W,
  parameter int unsigned ACC_W    = sa_pkg::ACC_W
)(
  input  logic                       clk,
  input  logic                       rst_n,

  // control
  input  logic                       acc_clear,   // sync clear of accumulator

  // streaming inputs
  input  logic signed [DATA_W-1:0]   a_in,        // activation, from west
  input  logic signed [WEIGHT_W-1:0] b_in,        // weight,     from north
  input  logic                       valid_in,    // accumulate this cycle?

  // streaming outputs (registered, propagated east/south)
  output logic signed [DATA_W-1:0]   a_out,
  output logic signed [WEIGHT_W-1:0] b_out,
  output logic                       valid_out,

  // accumulator output
  output logic signed [ACC_W-1:0]    acc_out
);

  logic signed [ACC_W-1:0]            acc_q;
  logic signed [DATA_W+WEIGHT_W-1:0]  product;

  // INT8 * INT8 -> INT16 product (signed)
  assign product = a_in * b_in;

  // ---------------------------------------------------------------------
  // Accumulator
  // ---------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      acc_q <= '0;
    else if (acc_clear)
      acc_q <= '0;
    else if (valid_in)
      acc_q <= acc_q + ACC_W'(product);   // sign-extend product to ACC_W
  end

  // ---------------------------------------------------------------------
  // Eastward / Southward registered pass-through
  // ---------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out     <= '0;
      b_out     <= '0;
      valid_out <= 1'b0;
    end else begin
      a_out     <= a_in;
      b_out     <= b_in;
      valid_out <= valid_in;
    end
  end

  assign acc_out = acc_q;

endmodule : pe

`default_nettype wire
