"""
Lightweight RV32I instruction encoder used by the cocotb tests.

Just enough of the ISA to build directed and random programs for the core.
Returns 32-bit integers.
"""

from __future__ import annotations


def _u(x: int, bits: int) -> int:
    return x & ((1 << bits) - 1)


# ---------------------------------------------------------------------------
# Format encoders
# ---------------------------------------------------------------------------
def encode_r(funct7: int, rs2: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    return (
        (_u(funct7, 7) << 25)
        | (_u(rs2, 5) << 20)
        | (_u(rs1, 5) << 15)
        | (_u(funct3, 3) << 12)
        | (_u(rd, 5) << 7)
        | _u(opcode, 7)
    )


def encode_i(imm: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    return (
        (_u(imm, 12) << 20)
        | (_u(rs1, 5) << 15)
        | (_u(funct3, 3) << 12)
        | (_u(rd, 5) << 7)
        | _u(opcode, 7)
    )


def encode_s(imm: int, rs2: int, rs1: int, funct3: int, opcode: int) -> int:
    imm = _u(imm, 12)
    imm_hi = (imm >> 5) & 0x7F
    imm_lo = imm & 0x1F
    return (
        (imm_hi << 25)
        | (_u(rs2, 5) << 20)
        | (_u(rs1, 5) << 15)
        | (_u(funct3, 3) << 12)
        | (imm_lo << 7)
        | _u(opcode, 7)
    )


def encode_b(imm: int, rs2: int, rs1: int, funct3: int, opcode: int) -> int:
    imm = _u(imm, 13)  # branch imm is 13-bit signed, low bit always 0
    b12 = (imm >> 12) & 1
    b11 = (imm >> 11) & 1
    b10_5 = (imm >> 5) & 0x3F
    b4_1 = (imm >> 1) & 0xF
    return (
        (b12 << 31)
        | (b10_5 << 25)
        | (_u(rs2, 5) << 20)
        | (_u(rs1, 5) << 15)
        | (_u(funct3, 3) << 12)
        | (b4_1 << 8)
        | (b11 << 7)
        | _u(opcode, 7)
    )


def encode_u(imm: int, rd: int, opcode: int) -> int:
    return (_u(imm, 32) & 0xFFFFF000) | (_u(rd, 5) << 7) | _u(opcode, 7)


def encode_j(imm: int, rd: int, opcode: int) -> int:
    imm = _u(imm, 21)
    b20 = (imm >> 20) & 1
    b10_1 = (imm >> 1) & 0x3FF
    b11 = (imm >> 11) & 1
    b19_12 = (imm >> 12) & 0xFF
    return (
        (b20 << 31)
        | (b10_1 << 21)
        | (b11 << 20)
        | (b19_12 << 12)
        | (_u(rd, 5) << 7)
        | _u(opcode, 7)
    )


# ---------------------------------------------------------------------------
# Convenience mnemonics — return uint32 instruction
# ---------------------------------------------------------------------------
NOP = 0x00000013  # addi x0, x0, 0


def addi(rd, rs1, imm):       return encode_i(imm, rs1, 0b000, rd, 0b0010011)
def slti(rd, rs1, imm):       return encode_i(imm, rs1, 0b010, rd, 0b0010011)
def sltiu(rd, rs1, imm):      return encode_i(imm, rs1, 0b011, rd, 0b0010011)
def xori(rd, rs1, imm):       return encode_i(imm, rs1, 0b100, rd, 0b0010011)
def ori(rd, rs1, imm):        return encode_i(imm, rs1, 0b110, rd, 0b0010011)
def andi(rd, rs1, imm):       return encode_i(imm, rs1, 0b111, rd, 0b0010011)
def slli(rd, rs1, sh):        return encode_i(sh & 0x1F, rs1, 0b001, rd, 0b0010011)
def srli(rd, rs1, sh):        return encode_i(sh & 0x1F, rs1, 0b101, rd, 0b0010011)
def srai(rd, rs1, sh):        return encode_i((sh & 0x1F) | (0x20 << 5), rs1, 0b101, rd, 0b0010011)

def add(rd, rs1, rs2):        return encode_r(0x00, rs2, rs1, 0b000, rd, 0b0110011)
def sub(rd, rs1, rs2):        return encode_r(0x20, rs2, rs1, 0b000, rd, 0b0110011)
def sll(rd, rs1, rs2):        return encode_r(0x00, rs2, rs1, 0b001, rd, 0b0110011)
def slt(rd, rs1, rs2):        return encode_r(0x00, rs2, rs1, 0b010, rd, 0b0110011)
def sltu(rd, rs1, rs2):       return encode_r(0x00, rs2, rs1, 0b011, rd, 0b0110011)
def xor_(rd, rs1, rs2):       return encode_r(0x00, rs2, rs1, 0b100, rd, 0b0110011)
def srl(rd, rs1, rs2):        return encode_r(0x00, rs2, rs1, 0b101, rd, 0b0110011)
def sra(rd, rs1, rs2):        return encode_r(0x20, rs2, rs1, 0b101, rd, 0b0110011)
def or_(rd, rs1, rs2):        return encode_r(0x00, rs2, rs1, 0b110, rd, 0b0110011)
def and_(rd, rs1, rs2):       return encode_r(0x00, rs2, rs1, 0b111, rd, 0b0110011)

def lb(rd, rs1, imm):         return encode_i(imm, rs1, 0b000, rd, 0b0000011)
def lh(rd, rs1, imm):         return encode_i(imm, rs1, 0b001, rd, 0b0000011)
def lw(rd, rs1, imm):         return encode_i(imm, rs1, 0b010, rd, 0b0000011)
def lbu(rd, rs1, imm):        return encode_i(imm, rs1, 0b100, rd, 0b0000011)
def lhu(rd, rs1, imm):        return encode_i(imm, rs1, 0b101, rd, 0b0000011)

def sb(rs2, imm, rs1):        return encode_s(imm, rs2, rs1, 0b000, 0b0100011)
def sh(rs2, imm, rs1):        return encode_s(imm, rs2, rs1, 0b001, 0b0100011)
def sw(rs2, imm, rs1):        return encode_s(imm, rs2, rs1, 0b010, 0b0100011)

def beq(rs1, rs2, imm):       return encode_b(imm, rs2, rs1, 0b000, 0b1100011)
def bne(rs1, rs2, imm):       return encode_b(imm, rs2, rs1, 0b001, 0b1100011)
def blt(rs1, rs2, imm):       return encode_b(imm, rs2, rs1, 0b100, 0b1100011)
def bge(rs1, rs2, imm):       return encode_b(imm, rs2, rs1, 0b101, 0b1100011)
def bltu(rs1, rs2, imm):      return encode_b(imm, rs2, rs1, 0b110, 0b1100011)
def bgeu(rs1, rs2, imm):      return encode_b(imm, rs2, rs1, 0b111, 0b1100011)

def jal(rd, imm):             return encode_j(imm, rd, 0b1101111)
def jalr(rd, rs1, imm):       return encode_i(imm, rs1, 0b000, rd, 0b1100111)

def lui(rd, imm):             return encode_u(imm, rd, 0b0110111)
def auipc(rd, imm):           return encode_u(imm, rd, 0b0010111)
