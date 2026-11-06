// Multiply and divide in the pipeline: operands forwarded into them, results forwarded out,
// back-to-back M instructions, a load feeding one, and branches/jumps right after one.
#include "common.h"

TEST_BEGIN
    // Operands forwarded in, result forwarded out.
    li   x5, 7
    li   x6, -3
    mul  x7, x5, x6          // both operands from MEM/WB
    addi x8, x7, 0           // result used right away
    NOP2
    CHECK(1, x8, 0xffffffeb) // -21

    // Back to back, each depending on the last.
    li   x5, 100
    li   x6, 7
    div  x7, x5, x6          // 14
    rem  x8, x5, x6          // 2
    mul  x9, x7, x8          // 28
    divu x10, x9, x8         // 14
    NOP2
    CHECK(2, x7, 14)
    CHECK(3, x8, 2)
    CHECK(4, x9, 28)
    CHECK(5, x10, 14)

    // High halves and signedness.
    li     x5, 0x80000000
    li     x6, 0xffffffff
    mulh   x7, x5, x6        // (-2^31 * -1) >> 32 = 0
    mulhu  x8, x5, x6        // 0x7fffffff
    mulhsu x9, x5, x6        // (-2^31 * (2^32-1)) >> 32 = 0x80000000
    NOP2
    CHECK(6, x7, 0)
    CHECK(7, x8, 0x7fffffff)
    CHECK(8, x9, 0x80000000)

    // Special cases: divide by zero and signed overflow.
    li   x5, -5
    div  x7, x5, x0          // -1
    rem  x8, x5, x0          // the dividend
    li   x6, 0x80000000
    li   x11, -1
    div  x9, x6, x11         // overflow: the dividend
    rem  x10, x6, x11        // 0
    NOP2
    CHECK(9, x7, 0xffffffff)
    CHECK(10, x8, 0xfffffffb)
    CHECK(11, x9, 0x80000000)
    CHECK(12, x10, 0)

    // A load feeding a multiply (load-use stall, then the unit).
    la   x12, data
    lw   x5, 0(x12)
    mul  x6, x5, x5
    NOP2
    CHECK(13, x6, 144)

    // A branch and a jump right after a divide: nothing on the wrong path may run.
    li   gp, 14
    li   x5, 9
    li   x6, 3
    divu x7, x5, x6
    beq  x7, x6, 1f          // taken: 3 == 3
    j    fail
1:  remu x8, x5, x6
    jal  x0, 1f
    j    fail
1:  NOP2
    CHECK(15, x8, 0)

    // A store of a multiply result.
    li   x5, 6
    mul  x6, x5, x5
    sw   x6, 4(x12)
    NOP2
    lw   x7, 4(x12)
    NOP2
    CHECK(16, x7, 36)
TEST_END

    .data
    .align 4
data:
    .word 12, 0
