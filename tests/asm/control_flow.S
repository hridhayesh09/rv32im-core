// Branches (taken and not taken), JAL, JALR, AUIPC and LUI. A `j fail` sits right after
// every taken branch or jump: if the core does not flush the wrong-path instructions, it
// runs that jump and fails. Data dependencies are spaced out, so this needs no forwarding.
#include "common.h"

#define TAKEN(n, op, a, b)     li gp, n; LI(x1, a); LI(x2, b); op x1, x2, 1f; j fail; 1:
#define NOT_TAKEN(n, op, a, b) li gp, n; LI(x1, a); LI(x2, b); op x1, x2, fail

TEST_BEGIN
    TAKEN     ( 1, beq,  7, 7)
    NOT_TAKEN ( 2, beq,  7, 8)
    TAKEN     ( 3, bne,  7, 8)
    NOT_TAKEN ( 4, bne,  7, 7)
    TAKEN     ( 5, blt,  0xffffffff, 0)      // -1 < 0
    NOT_TAKEN ( 6, blt,  0, 0xffffffff)
    NOT_TAKEN ( 7, blt,  5, 5)
    TAKEN     ( 8, bge,  5, 5)
    TAKEN     ( 9, bge,  0, 0xffffffff)
    NOT_TAKEN (10, bge,  0xffffffff, 0)
    TAKEN     (11, bltu, 0, 0xffffffff)
    NOT_TAKEN (12, bltu, 0xffffffff, 0)
    TAKEN     (13, bgeu, 0xffffffff, 0)
    NOT_TAKEN (14, bgeu, 0, 0xffffffff)

    // JAL writes the address of the next instruction.
    li gp, 15
    jal x5, 1f
jal_ret:
    j fail
    j fail
1:  NOP2
    CHECK(15, x5, jal_ret)

    // JALR, including an odd offset (bit 0 of the target is cleared).
    li gp, 16
    LI(x6, jalr_target)
    jalr x5, 1(x6)
jalr_ret:
    j fail
    j fail
jalr_target:
    NOP2
    CHECK(16, x5, jalr_ret)

    // JALR with rd == rs1: the jump uses the old value.
    li gp, 17
    LI(x6, jalr_target2)
    jalr x6, 0(x6)
jalr_ret2:
    j fail
jalr_target2:
    NOP2
    CHECK(17, x6, jalr_ret2)

    // Jumps to the very next instruction, back to back.
    li gp, 18
    j 1f
1:  j 1f
1:

    // AUIPC adds to its own address.
auipc_here:
    auipc x8, 0x1
    NOP2
    CHECK(19, x8, auipc_here + 0x1000)

    // Backward branch: a loop that runs 5 times.
    li x9, 5
    li x7, 0
    NOP2
loop:
    addi x9, x9, -1
    addi x7, x7, 1
    NOP2
    bne x9, x0, loop
    NOP2
    CHECK(20, x7, 5)
TEST_END
