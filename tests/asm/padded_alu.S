// Every RV32I ALU instruction on boundary values. Dependent instructions are spaced out,
// so this needs no forwarding.
#include "common.h"

#define RR(n, op, a, b, res)  LI(x1, a); LI(x2, b); op x13, x1, x2; NOP2; CHECK(n, x13, res)
#define RI(n, op, a, imm, res) LI(x1, a); op x13, x1, imm; NOP2; CHECK(n, x13, res)

TEST_BEGIN
    RR( 1, add,  0x7fffffff, 1,          0x80000000)
    RR( 2, add,  0xffffffff, 1,          0)
    RR( 3, sub,  0,          1,          0xffffffff)
    RR( 4, sub,  0x80000000, 1,          0x7fffffff)
    RR( 5, sll,  1,          31,         0x80000000)
    RR( 6, sll,  1,          32,         1)            // only the low 5 bits of the shift count
    RR( 7, srl,  0x80000000, 31,         1)
    RR( 8, sra,  0x80000000, 31,         0xffffffff)
    RR( 9, sra,  0x7fffffff, 30,         1)
    RR(10, slt,  0xffffffff, 1,          1)            // -1 < 1
    RR(11, slt,  1,          0xffffffff, 0)
    RR(12, sltu, 0xffffffff, 1,          0)            // 0xffffffff > 1 unsigned
    RR(13, sltu, 1,          0xffffffff, 1)
    RR(14, xor,  0x55555555, 0xffffffff, 0xaaaaaaaa)
    RR(15, or,   0x0f0f0f0f, 0xf0f0f0f0, 0xffffffff)
    RR(16, and,  0x0ff00ff0, 0x00ffff00, 0x00f00f00)

    RI(17, addi,  0x7fffffff, 1,     0x80000000)
    RI(18, addi,  0,          -2048, 0xfffff800)
    RI(19, slti,  0xfffff800, -2047, 1)
    RI(20, sltiu, 0,          -1,    1)                // immediate is sign-extended, then unsigned
    RI(21, xori,  0x12345678, -1,    0xedcba987)
    RI(22, ori,   0x12340000, 0x678, 0x12340678)
    RI(23, andi,  0x12345678, 0xff,  0x78)
    RI(24, slli,  3,          30,    0xc0000000)
    RI(25, srli,  0xc0000000, 30,    3)
    RI(26, srai,  0xc0000000, 30,    0xffffffff)

    // Writes to x0 are discarded.
    LI(x1, 5)
    add x0, x1, x1
    NOP2
    CHECK(27, x0, 0)
TEST_END
