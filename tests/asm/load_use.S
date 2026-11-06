// A loaded value used by the very next instruction: the core must stall one cycle.
// Covers every load size, rs1 and rs2 consumers, stores, branches, JALR, chains of loads,
// and cases that must NOT stall (load to x0, consumer that doesn't read the register).
#include "common.h"

TEST_BEGIN
    la x10, data

    // Each load size, used right away.
    lw   x5, 0(x10)
    addi x6, x5, 1              // rs1
    lb   x7, 0(x10)
    add  x8, x0, x7             // rs2
    lhu  x9, 2(x10)
    sub  x11, x9, x9            // both operands
    NOP2
    CHECK(1, x6, 0x80a1b2c4)
    CHECK(2, x8, 0xffffffc3)
    CHECK(3, x11, 0)

    // Load feeding a store's data and a store's address.
    lw   x12, 4(x10)            // = address of buf
    sw   x5, 0(x12)             // address depends on the load
    lw   x13, 0(x10)
    sw   x13, 4(x12)            // data depends on the load
    NOP2
    lw   x14, 0(x12)
    lw   x15, 4(x12)
    NOP2
    CHECK(4, x14, 0x80a1b2c3)
    CHECK(5, x15, 0x80a1b2c3)

    // Pointer chasing: each load's address comes from the load before it.
    lw   x16, 8(x10)            // -> node1
    lw   x16, 0(x16)            // -> node2
    lw   x16, 0(x16)            // -> 0x1234
    addi x17, x16, 0
    NOP2
    CHECK(6, x17, 0x1234)

    // Load feeding a branch and a JALR.
    li   gp, 7
    lw   x18, 0(x10)
    bne  x18, x5, fail
    lw   x19, 12(x10)           // = address of jalr_target
    jalr x0, 0(x19)
    j    fail
jalr_target:

    // No stall needed: load into x0, and a consumer that doesn't read the loaded register.
    lw   x0, 0(x10)
    addi x20, x0, 7
    lw   x21, 0(x10)
    lui  x21, 0x12345           // overwrites x21 without reading it
    NOP2
    CHECK(8, x20, 7)
    CHECK(9, x21, 0x12345000)
TEST_END

    .data
    .align 4
data:
    .word 0x80a1b2c3, buf, node1, jalr_target
node1:
    .word node2
node2:
    .word 0x1234
buf:
    .word 0, 0
