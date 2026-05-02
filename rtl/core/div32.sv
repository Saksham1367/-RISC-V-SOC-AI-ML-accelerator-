// =============================================================================
// div32.sv — Iterative 32-bit signed/unsigned divider (restoring division).
//
// Spec compliance (RISC-V Unprivileged ISA, M extension):
//   * DIV/DIVU produce quotient,  REM/REMU produce remainder.
//   * Signed remainder takes the sign of the dividend.
//   * Divide by zero: DIV  -> -1,                    REM  -> dividend
//                     DIVU -> 2^32 - 1 (all-ones),    REMU -> dividend
//   * Signed overflow (INT_MIN / -1):
//        DIV -> INT_MIN,   REM -> 0
//
// Latency: ~33 cycles. Stalls the pipeline via the `busy` signal.
//
// FSM:
//   S_IDLE  -> S_RUN (on `start`)
//   S_RUN   -> S_DONE (after 32 iterations OR on edge case)
//   S_DONE  -> S_IDLE (on `ack`)
//
// Handshake:
//   * Pulse `start` for one cycle while in S_IDLE; operands and op must be
//     stable on that cycle.
//   * `busy` is high while running (S_RUN). NOT high in S_DONE — the result
//     is stable and the EX/MEM register can capture it this cycle.
//   * `done` is high in S_DONE; `result` is stable as long as we are in
//     S_DONE. We stay in S_DONE until `ack` pulses (EX advances), so a
//     downstream stall (e.g., dmem_stall on MMIO) cannot make us drop the
//     result.
// =============================================================================
`default_nettype none

module div32
  import riscv_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  input  logic        start,
  input  logic [31:0] dividend,
  input  logic [31:0] divisor,
  input  div_op_e     op,

  input  logic        ack,        // EX advance: leave S_DONE -> S_IDLE

  output logic        busy,       // high in S_RUN only (stalls EX)
  output logic        done,       // high in S_DONE; result is valid
  output logic [31:0] result
);

  // ---------------------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    S_IDLE,
    S_RUN,
    S_DONE
  } state_e;

  state_e state_q;

  // Internal registers
  logic [63:0] rem_q_wide;     // {remainder[31:0], quotient[31:0]} shifter
  logic [31:0] divisor_q;      // unsigned divisor magnitude
  logic [5:0]  count_q;        // iteration counter
  logic        is_signed_q;    // signed op?
  logic        want_rem_q;     // want remainder (vs quotient)?
  logic        neg_quot_q;     // sign of final quotient
  logic        neg_rem_q;      // sign of final remainder
  logic        div_by_zero_q;
  logic        overflow_q;     // INT_MIN / -1
  logic [31:0] dividend_orig_q;

  // Operand decoding (combinational, latched on start)
  logic        op_signed;
  logic        op_want_rem;
  assign op_signed   = (op == DIV_OP_DIV)  || (op == DIV_OP_REM);
  assign op_want_rem = (op == DIV_OP_REM)  || (op == DIV_OP_REMU);

  logic dividend_neg, divisor_neg;
  assign dividend_neg = op_signed && dividend[31];
  assign divisor_neg  = op_signed && divisor[31];

  logic [31:0] dividend_abs, divisor_abs;
  assign dividend_abs = dividend_neg ? (~dividend + 32'd1) : dividend;
  assign divisor_abs  = divisor_neg  ? (~divisor  + 32'd1) : divisor;

  logic start_div_by_zero;
  logic start_overflow;
  assign start_div_by_zero = (divisor == 32'd0);
  // Signed overflow: INT_MIN / -1
  assign start_overflow    = op_signed
                          && (dividend == 32'h8000_0000)
                          && (divisor  == 32'hFFFF_FFFF);

  // Restoring division step (combinational)
  // rem_q_wide[63:32] = current partial remainder, [31:0] = quotient bits so
  // far. Shift left, then try to subtract divisor from the upper 32 bits.
  logic [63:0] shifted;
  logic [32:0] sub_result;
  assign shifted    = {rem_q_wide[62:0], 1'b0};
  assign sub_result = {1'b0, shifted[63:32]} - {1'b0, divisor_q};

  logic [63:0] step_next;
  always_comb begin
    if (sub_result[32] == 1'b0) begin
      // subtraction succeeded -> set quotient LSB, replace upper with diff
      step_next = {sub_result[31:0], shifted[31:1], 1'b1};
    end else begin
      // subtraction failed -> keep shifted upper, quotient LSB = 0
      step_next = {shifted[63:32],   shifted[31:1], 1'b0};
    end
  end

  // ---------------------------------------------------------------------------
  // Sequential logic
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q         <= S_IDLE;
      rem_q_wide      <= '0;
      divisor_q       <= '0;
      count_q         <= '0;
      is_signed_q     <= 1'b0;
      want_rem_q      <= 1'b0;
      neg_quot_q      <= 1'b0;
      neg_rem_q       <= 1'b0;
      div_by_zero_q   <= 1'b0;
      overflow_q      <= 1'b0;
      dividend_orig_q <= '0;
    end else begin
      unique case (state_q)
        S_IDLE: begin
          if (start) begin
            is_signed_q     <= op_signed;
            want_rem_q      <= op_want_rem;
            div_by_zero_q   <= start_div_by_zero;
            overflow_q      <= start_overflow;
            dividend_orig_q <= dividend;
            // Quotient sign: dividend XOR divisor (signed only)
            neg_quot_q      <= op_signed && (dividend_neg ^ divisor_neg);
            // Remainder takes sign of dividend
            neg_rem_q       <= dividend_neg;
            divisor_q       <= divisor_abs;
            rem_q_wide      <= {32'h0, dividend_abs};
            count_q         <= 6'd32;
            // Skip the iterations on edge cases — go straight to DONE.
            if (start_div_by_zero || start_overflow) begin
              state_q <= S_DONE;
            end else begin
              state_q <= S_RUN;
            end
          end
        end

        S_RUN: begin
          rem_q_wide <= step_next;
          count_q    <= count_q - 6'd1;
          if (count_q == 6'd1) begin
            state_q <= S_DONE;
          end
        end

        S_DONE: begin
          // Hold result until EX/MEM acknowledges. This is robust against
          // downstream stalls (mem_stall) on the cycle the divide finishes.
          if (ack) state_q <= S_IDLE;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Outputs
  // ---------------------------------------------------------------------------
  assign busy = (state_q == S_RUN);
  assign done = (state_q == S_DONE);

  // After 32 RUN cycles: rem_q_wide[63:32] = remainder, [31:0] = quotient.
  logic [31:0] quot_mag, rem_mag;
  assign quot_mag = rem_q_wide[31:0];
  assign rem_mag  = rem_q_wide[63:32];

  logic [31:0] quot_signed, rem_signed;
  assign quot_signed = neg_quot_q ? (~quot_mag + 32'd1) : quot_mag;
  assign rem_signed  = neg_rem_q  ? (~rem_mag  + 32'd1) : rem_mag;

  always_comb begin
    if (div_by_zero_q) begin
      // RISC-V spec for div-by-zero
      result = want_rem_q ? dividend_orig_q
                          : 32'hFFFF_FFFF;  // -1 signed and unsigned all-ones
    end else if (overflow_q) begin
      // INT_MIN / -1
      result = want_rem_q ? 32'd0
                          : 32'h8000_0000;  // INT_MIN
    end else begin
      result = want_rem_q ? rem_signed : quot_signed;
    end
  end

endmodule : div32

`default_nettype wire
