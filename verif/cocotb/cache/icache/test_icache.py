"""
Phase 2a — I-cache + AXI4-Full slave + SRAM standalone tests.

Verifies:
  * Cold miss: first request after reset misses, refills via AXI burst, then
    data appears with correct 1-cycle latency.
  * Sequential hits within a line: word 0..7 of a refilled line all hit
    without re-issuing a refill.
  * Stride that crosses a line boundary: triggers a second miss/refill.
  * Set conflict: addresses with the same set index but different tags
    cause cache evictions and re-fills.
  * Random sequence vs Python golden model.
"""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


MASK32 = (1 << 32) - 1
LINE_BYTES = 32
LINE_WORDS = 8
NUM_SETS = 128
WORD_OFF_LO = 2
WORD_OFF_HI = 4
SET_IDX_LO = 5
SET_IDX_HI = 11
TAG_LO = 12


def addr_to_word_idx(addr: int) -> int:
    return (addr >> 2) & 0x3FFF   # 16 KiB / 4 = 4096 words mask


async def reset(dut, cycles: int = 5):
    dut.rst_n.value = 0
    dut.cpu_re.value = 0
    dut.cpu_addr.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def seed_memory(dut, words: dict[int, int]):
    """Seed the AXI slave's backing SRAM. Word-indexed."""
    mem = dut.u_slave.u_sram.mem
    for idx, val in words.items():
        mem[idx].value = val & MASK32


async def fetch(dut, addr: int, max_wait_cycles: int = 200) -> tuple[int, int]:
    """Drive cpu_addr/re, wait for stall=0, then sample rdata 1 cycle later.

    Returns (rdata, cycles_waited).
    """
    dut.cpu_addr.value = addr
    dut.cpu_re.value = 1

    # Stall may go high combinationally on this same cycle.
    cycles = 0
    # Wait at least one rising edge to let the lookup propagate.
    await RisingEdge(dut.clk)
    cycles += 1
    while int(dut.cpu_stall.value) == 1:
        if cycles > max_wait_cycles:
            raise TimeoutError(
                f"fetch({addr:#x}): cache stall did not release within "
                f"{max_wait_cycles} cycles"
            )
        await RisingEdge(dut.clk)
        cycles += 1

    # stall is 0 now -> rdata is registered at the NEXT posedge.
    await RisingEdge(dut.clk)
    rdata = int(dut.cpu_rdata.value) & MASK32
    return rdata, cycles


async def deassert_re(dut):
    dut.cpu_re.value = 0
    await RisingEdge(dut.clk)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
@cocotb.test()
async def cold_miss_first_word(dut):
    """First fetch after reset misses; refill burst returns the line; data OK."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    expected = 0xDEADBEEF
    seed_memory(dut, {0: expected})
    await reset(dut)

    rdata, cycles = await fetch(dut, 0x0000_0000)
    assert rdata == expected, f"got {rdata:#x} expected {expected:#x}"
    # Cold miss should take at least 8 cycles (8-beat burst) plus a few for AR
    # handshake + register propagation. 5..40 cycles is the realistic range.
    assert 5 <= cycles <= 40, f"cold miss cycles = {cycles} (out of range)"


@cocotb.test()
async def sequential_hits_within_line(dut):
    """After the cold miss for word 0, words 1..7 hit instantly (1 cycle)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # Pre-populate words 0..7 of line 0 with distinct values.
    line = {i: 0x1000_0000 + i for i in range(LINE_WORDS)}
    seed_memory(dut, line)
    await reset(dut)

    # First fetch triggers a miss and refills the whole line.
    rdata0, cyc0 = await fetch(dut, 0x0)
    assert rdata0 == line[0], f"word0 got {rdata0:#x} expected {line[0]:#x}"

    # Subsequent fetches within the same line should be instant hits (1 cycle
    # of stall observation: stall=0 directly, then the registered rdata arrives
    # one cycle later — total 2 cycles in the fetch helper).
    for w in range(1, LINE_WORDS):
        addr = w * 4
        rdata, cyc = await fetch(dut, addr)
        assert rdata == line[w], f"word{w} got {rdata:#x} expected {line[w]:#x}"
        assert cyc <= 3, f"word{w} took {cyc} cycles — should be a fast hit"


@cocotb.test()
async def cross_line_triggers_second_miss(dut):
    """Fetching across the line boundary triggers a second refill burst."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # Two adjacent lines: line 0 (set 0, tag 0) and line 1 (set 1, tag 0).
    seed_memory(dut, {
        0:                   0xAA00_0000,   # word 0 of line 0
        LINE_WORDS - 1:      0xAA00_0007,   # word 7 of line 0
        LINE_WORDS:          0xBB00_0000,   # word 0 of line 1
    })
    await reset(dut)

    # Fetch line 0, word 0 — cold miss
    r0, cyc0 = await fetch(dut, 0x00)
    assert r0 == 0xAA00_0000

    # Fetch line 0, word 7 — hit
    r1, cyc1 = await fetch(dut, (LINE_WORDS - 1) * 4)
    assert r1 == 0xAA00_0007
    assert cyc1 <= 3

    # Fetch line 1, word 0 — second cold miss
    r2, cyc2 = await fetch(dut, LINE_BYTES)
    assert r2 == 0xBB00_0000
    assert cyc2 >= 5, f"line-1 cold miss took {cyc2} cycles (too fast)"


@cocotb.test()
async def set_conflict_eviction(dut):
    """Two addresses in the same set but different tags cause re-fill churn."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # Same set (index 0, since lower 12 bits except offset/byte differ within
    # a single line). To get same set index but different tags we step by
    # NUM_SETS * LINE_BYTES = 128 * 32 = 4096 bytes = 1 KiB.
    SET_STRIDE = NUM_SETS * LINE_BYTES
    addr_a = 0x0000_0000
    addr_b = SET_STRIDE  # Wait, this is 4096 byte-addr. As word index: 1024.

    # We need both addresses to fit inside the 16 KiB backing store
    # (4096 word entries, indices 0..4095). 4096-byte = word 1024. Fine.
    seed_memory(dut, {
        0:    0xCAFE_0000,
        1024: 0xCAFE_0001,
    })
    await reset(dut)

    # Miss A
    rA1, _ = await fetch(dut, addr_a)
    assert rA1 == 0xCAFE_0000

    # Miss B (same set, different tag — evicts A)
    rB1, _ = await fetch(dut, addr_b)
    assert rB1 == 0xCAFE_0001

    # Re-fetch A — must miss again because B evicted it.
    rA2, cycA2 = await fetch(dut, addr_a)
    assert rA2 == 0xCAFE_0000
    assert cycA2 >= 5, f"A refetch should miss (set conflict). cycles={cycA2}"


@cocotb.test()
async def random_sequence_vs_golden(dut):
    """Random fetch sequence: every result must match the seeded memory."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(0xA5A5)

    # Seed 256 words at random addresses within the slave's 16 KiB backing store.
    golden: dict[int, int] = {}
    for _ in range(256):
        word_idx = rng.randint(0, 4095)
        val = rng.randint(0, MASK32)
        golden[word_idx] = val
    seed_memory(dut, golden)
    await reset(dut)

    # Issue 60 random fetches (mix of new misses and re-hits).
    word_indices = list(golden.keys())
    for _ in range(60):
        word_idx = rng.choice(word_indices)
        addr = word_idx * 4
        rdata, _ = await fetch(dut, addr)
        assert rdata == golden[word_idx], \
            f"addr {addr:#x} (word {word_idx}): got {rdata:#x} expected {golden[word_idx]:#x}"
