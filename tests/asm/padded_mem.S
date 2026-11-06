// Loads and stores of every size, sign and byte offset. Dependent instructions are spaced
// out, so this needs no forwarding.
#include "common.h"

#define LOAD(n, op, off, res) op x13, off(x10); NOP2; CHECK(n, x13, res)

TEST_BEGIN
    LI(x10, words)

    LOAD( 1, lw,  0, 0x80a1b2c3)
    LOAD( 2, lb,  0, 0xffffffc3)     // sign-extended
    LOAD( 3, lbu, 0, 0x000000c3)     // zero-extended
    LOAD( 4, lb,  3, 0xffffff80)
    LOAD( 5, lbu, 2, 0x000000a1)
    LOAD( 6, lh,  0, 0xffffb2c3)
    LOAD( 7, lhu, 2, 0x000080a1)
    LOAD( 8, lh,  2, 0xffff80a1)

    LI(x5, 0x11223344)
    sw x5, 4(x10)
    sb x5, 8(x10)                    // byte lanes 0 and 3 of the word at +8
    sb x5, 11(x10)
    sh x5, 14(x10)                   // upper halfword of the word at +12
    LOAD( 9, lw,  4, 0x11223344)
    LOAD(10, lw,  8, 0x44000044)
    LOAD(11, lw, 12, 0x33440000)

    // Negative offset.
    addi x11, x10, 16
    NOP2
    lw x13, -16(x11)
    NOP2
    CHECK(12, x13, 0x80a1b2c3)
TEST_END

    .data
    .align 4
words:
    .word 0x80a1b2c3, 0, 0, 0
