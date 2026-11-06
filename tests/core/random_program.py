"""Random RV32IM test programs.

Each program starts with every register holding a random value, then runs a few hundred random
instructions: ALU ops, multiply/divide, loads and stores to a data buffer, forward branches and jumps, and small
counted loops (backward branches). Most instructions use a small pool of registers, so
back-to-back dependencies, forwarding and load-use stalls happen all the time.

There are no self-checks: the program is only correct if every retired instruction matches
Spike, which is what the lockstep test checks.
"""

import random

BUF_BYTES = 256
MEM_BASE = "x31"     # always points at the data buffer
JUMP_TMP = "x29"     # holds JALR targets
LOOP_REG = "x30"     # loop counter
GENERAL = [f"x{i}" for i in range(1, 29)]
HOT = ["x5", "x6", "x7", "x8"]   # used often, to create dependencies

RR = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
MULDIV = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
RI = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SHIFT_I = ["slli", "srli", "srai"]
LOADS = {"lb": 1, "lbu": 1, "lh": 2, "lhu": 2, "lw": 4}
STORES = {"sb": 1, "sh": 2, "sw": 4}
BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
INTERESTING = [0, 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x80000001, 0x0000FFFF, 0xFFFF0000]


class Generator:
    def __init__(self, seed):
        self.rng = random.Random(seed)

    def reg(self, allow_zero=True):
        r = self.rng.random()
        if allow_zero and r < 0.05:
            return "x0"
        if r < 0.6:
            return self.rng.choice(HOT)
        return self.rng.choice(GENERAL)

    def value(self):
        if self.rng.random() < 0.3:
            return self.rng.choice(INTERESTING)
        return self.rng.getrandbits(32)

    def imm12(self):
        return self.rng.choice([0, 1, -1, 2047, -2048, self.rng.randrange(-2048, 2048)])

    def simple(self):
        """One instruction that doesn't change control flow."""
        kind = self.rng.choices(["rr", "muldiv", "ri", "shift", "load", "store", "upper", "fence"],
                                weights=[30, 8, 25, 8, 15, 12, 8, 2])[0]
        rd, rs1, rs2 = self.reg(), self.reg(), self.reg()
        if kind == "rr":
            return f"{self.rng.choice(RR)} {rd}, {rs1}, {rs2}"
        if kind == "muldiv":
            return f"{self.rng.choice(MULDIV)} {rd}, {rs1}, {rs2}"
        if kind == "ri":
            return f"{self.rng.choice(RI)} {rd}, {rs1}, {self.imm12()}"
        if kind == "shift":
            return f"{self.rng.choice(SHIFT_I)} {rd}, {rs1}, {self.rng.randrange(32)}"
        if kind == "load":
            op, size = self.rng.choice(list(LOADS.items()))
            return f"{op} {rd}, {self.rng.randrange(0, BUF_BYTES, size)}({MEM_BASE})"
        if kind == "store":
            op, size = self.rng.choice(list(STORES.items()))
            return f"{op} {rs2}, {self.rng.randrange(0, BUF_BYTES, size)}({MEM_BASE})"
        if kind == "upper":
            return f"{self.rng.choice(['lui', 'auipc'])} {rd}, {self.rng.getrandbits(20)}"
        return "fence"

    def program(self, length):
        """Returns the program as a list of items; each item is a list of instruction lines.
        Branches and jumps name the index of the item they jump to (always forward)."""
        items, targets = [], set()
        for i in range(length):
            r = self.rng.random()
            if r < 0.12:
                target = min(i + 1 + self.rng.randrange(1, 8), length)
                targets.add(target)
                items.append([f"{self.rng.choice(BRANCHES)} {self.reg()}, {self.reg()}, L{target}"])
            elif r < 0.14:
                target = min(i + 1 + self.rng.randrange(1, 8), length)
                targets.add(target)
                items.append([f"jal {self.reg()}, L{target}"])
            elif r < 0.16:
                target = min(i + 1 + self.rng.randrange(1, 8), length)
                targets.add(target)
                items.append([f"la {JUMP_TMP}, L{target}", f"jalr {self.reg()}, 0({JUMP_TMP})"])
            elif r < 0.19:
                n = self.rng.randrange(1, 5)
                body = [self.simple() for _ in range(self.rng.randrange(1, 6))]
                items.append([f"li {LOOP_REG}, {n}", f"1:"] + body +
                             [f"addi {LOOP_REG}, {LOOP_REG}, -1", f"bnez {LOOP_REG}, 1b"])
            else:
                items.append([self.simple()])
        return items, targets

    def source(self, length=400):
        items, targets = self.program(length)
        lines = ['#include "common.h"', "TEST_BEGIN", f"    la {MEM_BASE}, buf"]
        for r in GENERAL:
            lines.append(f"    li {r}, {self.value():#x}")
        for i, item in enumerate(items):
            if i in targets:
                lines.append(f"L{i}:")
            lines += [f"    {line}" for line in item]
        lines.append(f"L{length}:")
        lines += ["TEST_END", "", "    .data", "    .align 4", "buf:"]
        lines += [f"    .word {self.rng.getrandbits(32):#x}" for _ in range(BUF_BYTES // 4)]
        return "\n".join(lines) + "\n"
