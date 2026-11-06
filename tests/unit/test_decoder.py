"""Decoder tests.

The expected results come from a table written straight from the RISC-V spec, and the
instructions are built by an encoder that is separate from the RTL: random field values
are packed into a word, and the decoder must unpack the same values.
"""

import random

import cocotb
from cocotb.triggers import Timer

from rv_defs import *
from sim import run

# mnemonic: (funct3, funct7, alu_op)
R_TYPE = {
    "add": (0, 0x00, ALU_ADD), "sub": (0, 0x20, ALU_SUB), "sll": (1, 0x00, ALU_SLL),
    "slt": (2, 0x00, ALU_SLT), "sltu": (3, 0x00, ALU_SLTU), "xor": (4, 0x00, ALU_XOR),
    "srl": (5, 0x00, ALU_SRL), "sra": (5, 0x20, ALU_SRA), "or": (6, 0x00, ALU_OR),
    "and": (7, 0x00, ALU_AND),
}
I_ARITH = {  # mnemonic: (funct3, alu_op)
    "addi": (0, ALU_ADD), "slti": (2, ALU_SLT), "sltiu": (3, ALU_SLTU),
    "xori": (4, ALU_XOR), "ori": (6, ALU_OR), "andi": (7, ALU_AND),
}
SHIFT_I = {"slli": (1, 0x00, ALU_SLL), "srli": (5, 0x00, ALU_SRL), "srai": (5, 0x20, ALU_SRA)}
M_TYPE = {"mul": 0, "mulh": 1, "mulhsu": 2, "mulhu": 3, "div": 4, "divu": 5, "rem": 6, "remu": 7}
LOADS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
STORES = {"sb": 0, "sh": 1, "sw": 2}
BRANCHES = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}

FLAGS = ["reg_write", "mem_read", "mem_write", "branch", "jal", "jalr", "muldiv", "fence_i",
         "uses_rs1", "uses_rs2", "ecall", "ebreak", "illegal"]


# ---- encoder (one function per instruction format) ----

def enc_r(op, f3, f7, rd, rs1, rs2):
    return f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op


def enc_i(op, f3, rd, rs1, imm):
    return (imm & 0xFFF) << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op


def enc_s(f3, rs1, rs2, imm):
    imm &= 0xFFF
    return (imm >> 5) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | (imm & 0x1F) << 7 | OP_STORE


def enc_b(f3, rs1, rs2, imm):
    imm &= 0x1FFF
    return ((imm >> 12) & 1) << 31 | ((imm >> 5) & 0x3F) << 25 | rs2 << 20 | rs1 << 15 \
        | f3 << 12 | ((imm >> 1) & 0xF) << 8 | ((imm >> 11) & 1) << 7 | OP_BRANCH


def enc_u(op, rd, imm20):
    return imm20 << 12 | rd << 7 | op


def enc_j(rd, imm):
    imm &= 0x1FFFFF
    return ((imm >> 20) & 1) << 31 | ((imm >> 1) & 0x3FF) << 21 | ((imm >> 11) & 1) << 20 \
        | ((imm >> 12) & 0xFF) << 12 | rd << 7 | OP_JAL


def expect(**fields):
    exp = {flag: 0 for flag in FLAGS}
    exp.update(fields)
    return exp


def random_instruction(rng):
    """Returns (mnemonic, instruction word, expected decoder outputs)."""
    rd, rs1, rs2 = rng.randrange(32), rng.randrange(32), rng.randrange(32)
    imm12 = rng.randrange(-2048, 2048)
    writes = int(rd != 0)
    kind = rng.choice(["r", "m", "i", "shift", "load", "store", "branch", "lui", "auipc",
                       "jal", "jalr", "fence", "fence_i", "ecall", "ebreak"])

    if kind == "r":
        name = rng.choice(list(R_TYPE))
        f3, f7, alu = R_TYPE[name]
        return name, enc_r(OP_OP, f3, f7, rd, rs1, rs2), expect(
            rd=rd, rs1=rs1, rs2=rs2, alu_op=alu, src_a=SRC_A_RS1, src_b=SRC_B_RS2,
            wb_sel=WB_ALU, reg_write=writes, uses_rs1=1, uses_rs2=1)
    if kind == "m":
        name = rng.choice(list(M_TYPE))
        return name, enc_r(OP_OP, M_TYPE[name], 0x01, rd, rs1, rs2), expect(
            rd=rd, rs1=rs1, rs2=rs2, funct3=M_TYPE[name], src_b=SRC_B_RS2,
            reg_write=writes, muldiv=1, uses_rs1=1, uses_rs2=1)
    if kind == "i":
        name = rng.choice(list(I_ARITH))
        f3, alu = I_ARITH[name]
        return name, enc_i(OP_IMM, f3, rd, rs1, imm12), expect(
            rd=rd, rs1=rs1, imm=imm12 & MASK32, alu_op=alu, src_a=SRC_A_RS1,
            src_b=SRC_B_IMM, wb_sel=WB_ALU, reg_write=writes, uses_rs1=1)
    if kind == "shift":
        name = rng.choice(list(SHIFT_I))
        f3, f7, alu = SHIFT_I[name]
        shamt = rng.randrange(32)
        return name, enc_r(OP_IMM, f3, f7, rd, rs1, shamt), expect(
            rd=rd, rs1=rs1, alu_op=alu, src_a=SRC_A_RS1, src_b=SRC_B_IMM,
            wb_sel=WB_ALU, reg_write=writes, uses_rs1=1)
    if kind == "load":
        name = rng.choice(list(LOADS))
        f3 = LOADS[name]
        return name, enc_i(OP_LOAD, f3, rd, rs1, imm12), expect(
            rd=rd, rs1=rs1, imm=imm12 & MASK32, funct3=f3, alu_op=ALU_ADD, src_a=SRC_A_RS1,
            src_b=SRC_B_IMM, wb_sel=WB_MEM, reg_write=writes, mem_read=1, uses_rs1=1)
    if kind == "store":
        name = rng.choice(list(STORES))
        f3 = STORES[name]
        return name, enc_s(f3, rs1, rs2, imm12), expect(
            rs1=rs1, rs2=rs2, imm=imm12 & MASK32, funct3=f3, alu_op=ALU_ADD,
            src_a=SRC_A_RS1, src_b=SRC_B_IMM, mem_write=1, uses_rs1=1, uses_rs2=1)
    if kind == "branch":
        name = rng.choice(list(BRANCHES))
        f3 = BRANCHES[name]
        imm = rng.randrange(-4096, 4096, 2)
        return name, enc_b(f3, rs1, rs2, imm), expect(
            rs1=rs1, rs2=rs2, imm=imm & MASK32, funct3=f3, branch=1, uses_rs1=1, uses_rs2=1)
    if kind in ("lui", "auipc"):
        imm20 = rng.getrandbits(20)
        op, src_a = (OP_LUI, SRC_A_ZERO) if kind == "lui" else (OP_AUIPC, SRC_A_PC)
        return kind, enc_u(op, rd, imm20), expect(
            rd=rd, imm=imm20 << 12, alu_op=ALU_ADD, src_a=src_a, src_b=SRC_B_IMM,
            wb_sel=WB_ALU, reg_write=writes)
    if kind == "jal":
        imm = rng.randrange(-(1 << 20), 1 << 20, 2)
        return kind, enc_j(rd, imm), expect(
            rd=rd, imm=imm & MASK32, wb_sel=WB_PC4, reg_write=writes, jal=1)
    if kind == "jalr":
        return kind, enc_i(OP_JALR, 0, rd, rs1, imm12), expect(
            rd=rd, rs1=rs1, imm=imm12 & MASK32, wb_sel=WB_PC4, reg_write=writes,
            jalr=1, uses_rs1=1)
    if kind == "fence":
        return kind, enc_i(OP_MISC_MEM, 0, rd, rs1, rng.getrandbits(12)), expect()
    if kind == "fence_i":
        return kind, enc_i(OP_MISC_MEM, 1, 0, 0, 0), expect(fence_i=1)
    if kind == "ecall":
        return kind, 0x00000073, expect(ecall=1)
    return kind, 0x00100073, expect(ebreak=1)


def is_legal(w):
    """Which words are legal RV32IM instructions on this core, from the spec's opcode map."""
    op, f3, f7 = w & 0x7F, (w >> 12) & 7, w >> 25
    if op in (OP_LUI, OP_AUIPC, OP_JAL):
        return True
    if op == OP_JALR:
        return f3 == 0
    if op == OP_BRANCH:
        return f3 not in (2, 3)
    if op == OP_LOAD:
        return f3 in (0, 1, 2, 4, 5)
    if op == OP_STORE:
        return f3 in (0, 1, 2)
    if op == OP_IMM:
        if f3 == 1:
            return f7 == 0
        if f3 == 5:
            return f7 in (0, 0x20)
        return True
    if op == OP_OP:
        return f7 in (0, 1) or (f7 == 0x20 and f3 in (0, 5))   # f7 = 1: M extension
    if op == OP_MISC_MEM:
        return f3 in (0, 1)  # FENCE, FENCE.I
    if op == OP_SYSTEM:
        return w in (0x00000073, 0x00100073)
    return False


async def decode(dut, word):
    dut.instr.value = word
    await Timer(1, unit="ns")


def check(dut, name, word, exp):
    for field, value in exp.items():
        got = int(getattr(dut, field).value)
        assert got == value, f"{name} {word:#010x}: {field} = {got:#x}, expected {value:#x}"


@cocotb.test()
async def every_instruction_random_fields(dut):
    rng = random.Random(3)
    for _ in range(20000):
        name, word, exp = random_instruction(rng)
        await decode(dut, word)
        check(dut, name, word, exp)


@cocotb.test()
async def immediate_extremes(dut):
    """Largest positive and negative immediates in every format, where sign bugs show up."""
    cases = []
    for imm in (-2048, -1, 0, 2047):
        cases += [("addi", enc_i(OP_IMM, 0, 1, 2, imm), imm), ("sw", enc_s(2, 1, 2, imm), imm)]
    for imm in (-4096, -2, 2, 4094):
        cases.append(("beq", enc_b(0, 1, 2, imm), imm))
    for imm in (-(1 << 20), -2, 2, (1 << 20) - 2):
        cases.append(("jal", enc_j(1, imm), imm))
    for imm20 in (0, 1, 0x80000, 0xFFFFF):
        cases.append(("lui", enc_u(OP_LUI, 1, imm20), imm20 << 12))
    for name, word, imm in cases:
        await decode(dut, word)
        check(dut, name, word, {"imm": imm & MASK32})


@cocotb.test()
async def illegal_instructions(dut):
    """Random words, and legal words with funct3/funct7/opcode bits flipped."""
    rng = random.Random(4)
    for i in range(40000):
        if i % 2:
            word = rng.getrandbits(32)
        else:
            _, word, _ = random_instruction(rng)
            word ^= rng.getrandbits(7) << 25 | rng.getrandbits(3) << 12 | rng.getrandbits(7)
        await decode(dut, word)
        legal = is_legal(word)
        check(dut, "word", word, {"illegal": int(not legal)})
        if not legal:
            check(dut, "illegal", word, {f: 0 for f in FLAGS if f != "illegal"})


def test_decoder():
    run("decoder", ["decoder.sv"], "test_decoder")
