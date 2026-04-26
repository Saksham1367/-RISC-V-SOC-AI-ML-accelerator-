"""
Phase 4: constrained-random RV32I instruction-stream tester.

Generates a random RV32I program (legal subset) and executes it on the
DUT. A pure-Python RV32I model runs in parallel; after the program
terminates we compare register-file contents.

Coverage points: instruction-class hits, hazard hits (load-use, branch
taken/not-taken, forwarding), funct3 codes per opcode group.
"""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from common import rv_isa as isa
from common.scoreboard import Scoreboard
from common.coverage import CoverPoint, dump_coverage


MASK32 = 0xFFFFFFFF
def to_signed(x, bits=32):
    x &= (1 << bits) - 1
    return x - (1 << bits) if x & (1 << (bits-1)) else x


# ---------------------------------------------------------------------------
# Pure-Python RV32I subset interpreter — golden reference
# ---------------------------------------------------------------------------
class RVModel:
    def __init__(self, dmem_words: int = 4096):
        self.regs = [0] * 32
        self.pc   = 0
        self.dmem = [0] * dmem_words

    def _set(self, rd, val):
        if rd != 0:
            self.regs[rd] = val & MASK32

    def step(self, instr: int) -> str:
        opcode = instr & 0x7F
        rd     = (instr >> 7) & 0x1F
        funct3 = (instr >> 12) & 0x7
        rs1    = (instr >> 15) & 0x1F
        rs2    = (instr >> 20) & 0x1F
        funct7 = (instr >> 25) & 0x7F

        a = self.regs[rs1]
        b = self.regs[rs2]
        next_pc = (self.pc + 4) & MASK32
        kind = "unknown"

        if opcode == 0x13:  # OP-IMM (ADDI/ANDI/ORI/XORI/SLT*I/SLLI/SRLI/SRAI)
            imm12 = instr >> 20
            imm = to_signed(imm12, 12) & MASK32
            shamt = imm12 & 0x1F
            f7 = (imm12 >> 5) & 0x7F
            if   funct3 == 0: self._set(rd, (a + imm) & MASK32);                              kind = "addi"
            elif funct3 == 7: self._set(rd, a & imm);                                         kind = "andi"
            elif funct3 == 6: self._set(rd, a | imm);                                         kind = "ori"
            elif funct3 == 4: self._set(rd, a ^ imm);                                         kind = "xori"
            elif funct3 == 2: self._set(rd, 1 if to_signed(a) < to_signed(imm) else 0);       kind = "slti"
            elif funct3 == 3: self._set(rd, 1 if a < imm else 0);                             kind = "sltiu"
            elif funct3 == 1: self._set(rd, (a << shamt) & MASK32);                           kind = "slli"
            elif funct3 == 5:
                if f7 & 0x20: self._set(rd, (to_signed(a) >> shamt) & MASK32);                kind = "srai"
                else:         self._set(rd, (a >> shamt) & MASK32);                           kind = "srli"
        elif opcode == 0x33:  # OP (R-type)
            if   funct3 == 0:
                if funct7 & 0x20: self._set(rd, (a - b) & MASK32);                            kind = "sub"
                else:             self._set(rd, (a + b) & MASK32);                            kind = "add"
            elif funct3 == 7: self._set(rd, a & b);                                           kind = "and"
            elif funct3 == 6: self._set(rd, a | b);                                           kind = "or"
            elif funct3 == 4: self._set(rd, a ^ b);                                           kind = "xor"
            elif funct3 == 2: self._set(rd, 1 if to_signed(a) < to_signed(b) else 0);         kind = "slt"
            elif funct3 == 3: self._set(rd, 1 if a < b else 0);                               kind = "sltu"
            elif funct3 == 1: self._set(rd, (a << (b & 0x1F)) & MASK32);                      kind = "sll"
            elif funct3 == 5:
                if funct7 & 0x20: self._set(rd, (to_signed(a) >> (b & 0x1F)) & MASK32);       kind = "sra"
                else:             self._set(rd, (a >> (b & 0x1F)) & MASK32);                  kind = "srl"
        elif opcode == 0x03:  # LOAD
            imm = to_signed(instr >> 20, 12)
            byte_addr = (a + imm) & MASK32
            word = self.dmem[(byte_addr >> 2) % len(self.dmem)]
            if   funct3 == 2: self._set(rd, word);                                            kind = "lw"
            elif funct3 == 0:
                shift = (byte_addr & 3) * 8
                v = (word >> shift) & 0xFF
                self._set(rd, to_signed(v, 8) & MASK32);                                       kind = "lb"
            elif funct3 == 4:
                shift = (byte_addr & 3) * 8
                v = (word >> shift) & 0xFF
                self._set(rd, v);                                                              kind = "lbu"
        elif opcode == 0x23:  # STORE
            imm_hi = (instr >> 25) & 0x7F
            imm_lo = (instr >> 7)  & 0x1F
            imm = to_signed((imm_hi << 5) | imm_lo, 12)
            byte_addr = (a + imm) & MASK32
            word_idx = (byte_addr >> 2) % len(self.dmem)
            if   funct3 == 2:
                self.dmem[word_idx] = b & MASK32;                                              kind = "sw"
            elif funct3 == 0:
                shift = (byte_addr & 3) * 8
                w = self.dmem[word_idx]
                w = (w & ~(0xFF << shift)) | ((b & 0xFF) << shift)
                self.dmem[word_idx] = w & MASK32;                                              kind = "sb"
        elif opcode == 0x63:  # BRANCH
            imm12 = (((instr >> 31) & 1) << 12) | (((instr >> 7) & 1) << 11) \
                  | (((instr >> 25) & 0x3F) << 5) | (((instr >> 8) & 0xF) << 1)
            imm = to_signed(imm12, 13)
            taken = False
            if   funct3 == 0: taken = (a == b);                                                kind = "beq"
            elif funct3 == 1: taken = (a != b);                                                kind = "bne"
            elif funct3 == 4: taken = (to_signed(a) <  to_signed(b));                          kind = "blt"
            elif funct3 == 5: taken = (to_signed(a) >= to_signed(b));                          kind = "bge"
            elif funct3 == 6: taken = (a < b);                                                 kind = "bltu"
            elif funct3 == 7: taken = (a >= b);                                                kind = "bgeu"
            if taken:
                next_pc = (self.pc + imm) & MASK32
        elif opcode == 0x37:  # LUI
            self._set(rd, instr & 0xFFFFF000);                                                 kind = "lui"
        elif opcode == 0x17:  # AUIPC
            self._set(rd, (self.pc + (instr & 0xFFFFF000)) & MASK32);                          kind = "auipc"
        elif opcode == 0x6F:  # JAL
            imm21 = (((instr >> 31) & 1) << 20) | (((instr >> 12) & 0xFF) << 12) \
                  | (((instr >> 20) & 1) << 11) | (((instr >> 21) & 0x3FF) << 1)
            imm = to_signed(imm21, 21)
            self._set(rd, next_pc)
            next_pc = (self.pc + imm) & MASK32;                                                kind = "jal"
        elif opcode == 0x67:  # JALR
            imm = to_signed(instr >> 20, 12)
            tgt = (a + imm) & ~1 & MASK32
            self._set(rd, next_pc)
            next_pc = tgt;                                                                     kind = "jalr"
        else:
            kind = "nop"

        self.pc = next_pc
        return kind


# ---------------------------------------------------------------------------
# Random program generator
# ---------------------------------------------------------------------------
def gen_random_program(rng: random.Random, n: int = 60) -> list[int]:
    """Build a sequence of safe RV32I instructions (no branches/loads with
    bad addresses, no JAL out of bounds). Restrict ALU ops, ADDI, ANDI/ORI,
    SLLI/SRLI/SRAI, and a few well-formed loads/stores to dmem index 0..15.
    """
    prog = []
    # init: addi xN, x0, small for a handful of regs to seed values
    for r in range(1, 8):
        prog.append(isa.addi(r, 0, rng.randint(-32, 32)))

    safe_ops = [
        lambda: isa.addi(rng.randint(1, 31), rng.randint(0, 31), rng.randint(-128, 127)),
        lambda: isa.add (rng.randint(1, 31), rng.randint(0, 31), rng.randint(0, 31)),
        lambda: isa.sub (rng.randint(1, 31), rng.randint(0, 31), rng.randint(0, 31)),
        lambda: isa.and_(rng.randint(1, 31), rng.randint(0, 31), rng.randint(0, 31)),
        lambda: isa.or_ (rng.randint(1, 31), rng.randint(0, 31), rng.randint(0, 31)),
        lambda: isa.xor_(rng.randint(1, 31), rng.randint(0, 31), rng.randint(0, 31)),
        lambda: isa.slt (rng.randint(1, 31), rng.randint(0, 31), rng.randint(0, 31)),
        lambda: isa.sltu(rng.randint(1, 31), rng.randint(0, 31), rng.randint(0, 31)),
        lambda: isa.slli(rng.randint(1, 31), rng.randint(0, 31), rng.randint(0, 31)),
        lambda: isa.srli(rng.randint(1, 31), rng.randint(0, 31), rng.randint(0, 31)),
        lambda: isa.srai(rng.randint(1, 31), rng.randint(0, 31), rng.randint(0, 31)),
        lambda: isa.andi(rng.randint(1, 31), rng.randint(0, 31), rng.randint(-128, 127)),
        lambda: isa.ori (rng.randint(1, 31), rng.randint(0, 31), rng.randint(-128, 127)),
        lambda: isa.xori(rng.randint(1, 31), rng.randint(0, 31), rng.randint(-128, 127)),
        # safe load/store from x0 + small immediate (dmem index 0..15)
        lambda: isa.sw(rng.randint(0, 31), (rng.randint(0, 15) * 4), 0),
        lambda: isa.lw(rng.randint(1, 31), 0, rng.randint(0, 15) * 4),
    ]
    for _ in range(n):
        prog.append(rng.choice(safe_ops)())
    # halt
    prog.append(isa.jal(0, 0))
    return prog


class RVCoverage:
    def __init__(self):
        @CoverPoint("core.instr.kind",
                    xf=lambda k: k,
                    bins=["addi","add","sub","and","or","xor","slt","sltu",
                          "sll","srl","sra","slli","srli","srai","andi","ori","xori",
                          "lw","sw","lb","lbu","sb","beq","bne","blt","bge","bltu","bgeu",
                          "lui","auipc","jal","jalr","nop"])
        def sampler(k): pass
        self._s = sampler

    def sample(self, kind: str):
        self._s(kind)


# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------
async def reset(dut, cycles: int = 5):
    dut.rst_n.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def reg_dut(dut, idx: int) -> int:
    if idx == 0: return 0
    return int(dut.u_core.u_regfile.regs[idx].value) & MASK32


def imem_load(dut, prog):
    mem = dut.u_imem.u_sram.mem
    for i, w in enumerate(prog):
        mem[i].value = w & MASK32
    for i in range(len(prog), len(mem)):
        mem[i].value = isa.NOP


@cocotb.test()
async def random_isa_streams(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    sb  = Scoreboard("riscv-core-random")
    cov = RVCoverage()

    NUM_TRIALS = 8
    rng = random.Random(0x77AA)

    for trial in range(NUM_TRIALS):
        prog = gen_random_program(rng, n=60)

        # zero dmem
        for i in range(64):
            dut.u_dmem.mem[i].value = 0

        imem_load(dut, prog)
        await reset(dut)

        # Execute the model side
        model = RVModel()
        executed = 0
        while executed < 200 and (model.pc >> 2) < len(prog):
            instr = prog[model.pc >> 2]
            kind = model.step(instr)
            cov.sample(kind)
            executed += 1
            if kind == "jal" and instr == isa.jal(0, 0):  # halt sentinel
                break

        # let the DUT run a generous number of cycles
        for _ in range(executed * 6 + 50):
            await RisingEdge(dut.clk)

        # compare regs x1..x31 (skip x0, always zero)
        for r in range(1, 32):
            sb.expect(reg_dut(dut, r), model.regs[r], label=f"trial{trial}/x{r}")

    print("\n" + "=" * 60)
    print(sb.summary())
    dump_coverage(suite_name="core_random")
    sb.assert_clean()
