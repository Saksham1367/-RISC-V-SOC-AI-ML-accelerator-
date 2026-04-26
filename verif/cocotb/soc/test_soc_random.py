"""
Phase 4: constrained-random + scoreboard + functional coverage at the SoC level.

Re-uses the assemble_program helper from test_soc.py to drive matrix
multiplications through the RV32I program path. Each iteration:
  1. Generates a random pair of 4x4 INT8 matrices (with constraints to
     hit interesting corners — zeros, signs, max values).
  2. Loads the program + operands, runs, reads C from data SRAM.
  3. Compares against NumPy golden via Scoreboard.
  4. Samples functional coverage points: matrix sign mix, overflow risk,
     non-zero density, and result-magnitude buckets.
"""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from common.scoreboard import Scoreboard
from common.coverage import CoverPoint, CoverCross, dump_coverage

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

# Re-use program / IO helpers from the directed SoC test
from test_soc import (
    N, A_PACKED_OFF, B_PACKED_OFF, C_RESULT_OFF,
    pack_row, golden,
    assemble_program, imem_load, dmem_write_word, dmem_read_word,
    s32, reset, run_program,
)


# ---------------------------------------------------------------------------
# Coverage point sampler
# ---------------------------------------------------------------------------
class MatmulCoverage:
    """Wraps cocotb_coverage CoverPoints. We sample one record per matmul."""

    def __init__(self):
        @CoverPoint("top.matmul.a_sign", xf=lambda r: r["a_sign_mix"],
                    bins=["all_pos", "all_neg", "mixed", "all_zero"])
        @CoverPoint("top.matmul.b_sign", xf=lambda r: r["b_sign_mix"],
                    bins=["all_pos", "all_neg", "mixed", "all_zero"])
        @CoverPoint("top.matmul.density", xf=lambda r: r["density"],
                    bins=["sparse", "medium", "dense"])
        @CoverPoint("top.matmul.max_abs", xf=lambda r: r["max_bin"],
                    bins=["small", "medium", "large", "max"])
        @CoverCross("top.matmul.cross.sign_density",
                    items=["top.matmul.a_sign", "top.matmul.density"])
        def sampler(r):
            pass
        self._sampler = sampler

    def sample(self, A, B):
        flat_a = [v for row in A for v in row]
        flat_b = [v for row in B for v in row]

        def sign_mix(xs):
            pos = any(v > 0 for v in xs)
            neg = any(v < 0 for v in xs)
            if not pos and not neg: return "all_zero"
            if pos and not neg:     return "all_pos"
            if neg and not pos:     return "all_neg"
            return "mixed"

        nonzero_density = sum(1 for v in flat_a + flat_b if v != 0)
        density = (
            "sparse" if nonzero_density < 12 else
            "medium" if nonzero_density < 24 else
            "dense"
        )
        max_abs = max((abs(v) for v in flat_a + flat_b), default=0)
        max_bin = (
            "small"  if max_abs <= 8 else
            "medium" if max_abs <= 32 else
            "large"  if max_abs <= 100 else
            "max"
        )
        record = {
            "a_sign_mix": sign_mix(flat_a),
            "b_sign_mix": sign_mix(flat_b),
            "density":    density,
            "max_bin":    max_bin,
        }
        self._sampler(record)


# ---------------------------------------------------------------------------
# Constrained random matrix generators
# ---------------------------------------------------------------------------
def gen_random_matrix(rng: random.Random, mode: str) -> list[list[int]]:
    if mode == "all_zero":
        return [[0]*N for _ in range(N)]
    if mode == "small_pos":
        return [[rng.randint(0, 8) for _ in range(N)] for _ in range(N)]
    if mode == "small_neg":
        return [[-rng.randint(0, 8) for _ in range(N)] for _ in range(N)]
    if mode == "max_corners":
        return [[rng.choice([-128, -1, 0, 1, 127]) for _ in range(N)] for _ in range(N)]
    if mode == "sparse":
        return [[rng.choice([0, 0, 0, rng.randint(-32, 32)]) for _ in range(N)] for _ in range(N)]
    # default: full random
    return [[rng.randint(-128, 127) for _ in range(N)] for _ in range(N)]


# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------
@cocotb.test()
async def random_with_coverage(dut):
    """50 random matmuls with constrained mode mix; scoreboard + coverage."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    sb  = Scoreboard("soc-random-matmul")
    cov = MatmulCoverage()

    rng = random.Random(0xC0FE)
    modes = [
        "full",       # 60%
        "full",
        "full",
        "full",
        "full",
        "full",
        "all_zero",   # 5%
        "small_pos",  # 10%
        "small_neg",  # 10%
        "sparse",     # 10%
        "max_corners",# 5%
    ]

    for trial in range(50):
        mode_a = rng.choice(modes)
        mode_b = rng.choice(modes)
        A = gen_random_matrix(rng, mode_a)
        B = gen_random_matrix(rng, mode_b)

        cov.sample(A, B)
        E = golden(A, B)
        C = await run_program(dut, A, B)

        sb.expect(C, E, label=f"trial{trial}/{mode_a}x{mode_b}")

    print("\n" + "=" * 60)
    print(sb.summary())

    dump_coverage(suite_name="soc_random")
    sb.assert_clean()
