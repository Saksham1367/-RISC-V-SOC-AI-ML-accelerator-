// =============================================================================
// cache_pkg.sv — Common parameters and address-breakdown helpers for the
// SEDA L1 caches. Both I-cache and D-cache share these settings:
//   * 4 KB total
//   * 32-byte (8-word) lines
//   * Direct-mapped (1 way)
//   * 128 sets
//
// Address breakdown for a 32-bit byte address with these geometry:
//   bit[31..12] = tag                   (20 bits)
//   bit[11..5]  = set index             (7 bits, 128 sets)
//   bit[4..2]   = word offset within line (3 bits, 8 words)
//   bit[1..0]   = byte offset within word (2 bits)
//
// AXI4-Full burst configuration for line refills:
//   * 8-beat INCR burst, 4-byte beats — exactly one cache line per request
//   * ARLEN  = 7  (= 8 - 1)
//   * ARSIZE = 2  (4 bytes per beat)
//   * ARBURST = INCR (2'b01)
// =============================================================================
`ifndef CACHE_PKG_SV
`define CACHE_PKG_SV

package cache_pkg;

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------
  localparam int unsigned LINE_BYTES   = 32;
  localparam int unsigned LINE_WORDS   = LINE_BYTES / 4;          // 8
  localparam int unsigned NUM_SETS     = 128;
  localparam int unsigned CACHE_BYTES  = LINE_BYTES * NUM_SETS;   // 4 KiB

  // ---------------------------------------------------------------------------
  // Address breakdown (byte address, 32-bit)
  // ---------------------------------------------------------------------------
  localparam int unsigned BYTE_OFF_BITS  = 2;    // [1:0]
  localparam int unsigned WORD_OFF_BITS  = 3;    // [4:2]
  localparam int unsigned SET_IDX_BITS   = 7;    // [11:5]
  localparam int unsigned TAG_BITS       = 32 - SET_IDX_BITS - WORD_OFF_BITS - BYTE_OFF_BITS;  // 20

  localparam int unsigned BYTE_OFF_LO    = 0;
  localparam int unsigned BYTE_OFF_HI    = 1;
  localparam int unsigned WORD_OFF_LO    = 2;
  localparam int unsigned WORD_OFF_HI    = 4;
  localparam int unsigned SET_IDX_LO     = 5;
  localparam int unsigned SET_IDX_HI     = 11;
  localparam int unsigned TAG_LO         = 12;
  localparam int unsigned TAG_HI         = 31;

  // ---------------------------------------------------------------------------
  // AXI4-Full burst constants
  // ---------------------------------------------------------------------------
  localparam logic [7:0] AXI_BURST_LEN  = 8'd7;     // = LINE_WORDS - 1
  localparam logic [2:0] AXI_BURST_SIZE = 3'd2;     // 2^2 = 4 bytes
  localparam logic [1:0] AXI_BURST_INCR = 2'b01;

endpackage : cache_pkg

`endif // CACHE_PKG_SV
