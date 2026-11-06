// Back-to-back dependent instructions with no spacing: each result must be forwarded from
// MEM (1 instruction later), WB (2 later) or the register file bypass (3 later).
// Results are only checked after spacing (CHECK), so a failure points at the forwarding.
#include "common.h"

TEST_BEGIN
    // Distance 1, 2 and 3, on rs1 and rs2.
    li   x5, 10
    addi x6, x5, 1          // rs1 from MEM               -> 11
    add  x7, x6, x5         // rs1 from MEM, rs2 from WB   -> 21
    sub  x8, x5, x7         // rs1 from regfile, rs2 MEM  -> -11
    NOP2
    CHECK(1, x6, 11)
    CHECK(2, x7, 21)
    CHECK(3, x8, 0xfffffff5)

    // A chain where every instruction needs the one just before: 1 doubled 10 times.
    li  x5, 1
    add x5, x5, x5
    add x5, x5, x5
    add x5, x5, x5
    add x5, x5, x5
    add x5, x5, x5
    add x5, x5, x5
    add x5, x5, x5
    add x5, x5, x5
    add x5, x5, x5
    add x5, x5, x5
    NOP2
    CHECK(4, x5, 1024)

    // Two writes to the same register in a row: the newer one (in MEM) must win over WB.
    li   x9, 1
    li   x9, 2
    addi x10, x9, 0
    NOP2
    CHECK(5, x10, 2)

    // li/la of a full 32-bit value is LUI/AUIPC + ADDI back to back.
    li x11, 0x12345678
    NOP2
    CHECK(6, x11, 0x12345678)

    // Store address and store data, both forwarded; read back after spacing.
    la   x12, buf
    li   x14, 0x55
    sw   x14, 0(x12)        // rs1 from WB, rs2 from MEM
    addi x12, x12, 4
    sw   x14, 0(x12)        // rs1 from MEM
    NOP2
    lw   x15, -4(x12)
    lw   x16, 0(x12)
    NOP2
    CHECK(7, x15, 0x55)
    CHECK(8, x16, 0x55)

    // A loaded value used two instructions later comes from WB.
    lw   x17, 0(x12)
    nop
    addi x18, x17, 1
    NOP2
    CHECK(9, x18, 0x56)

    // Branch operands forwarded.
    li  gp, 10
    li  x19, 3
    li  x20, 3
    beq x19, x20, 1f        // rs1 from WB, rs2 from MEM
    j   fail
1:
    li  gp, 11
    li  x19, 4
    bne x19, x20, 1f        // rs1 from MEM, rs2 from regfile
    j   fail
1:

    // JALR base forwarded.
    li   gp, 12
    la   x21, 1f
    jalr x0, 0(x21)
    j    fail
1:

    // AUIPC and JAL results forwarded.
auipc_here:
    auipc x22, 0
    addi  x23, x22, 0
    NOP2
    CHECK(13, x23, auipc_here)
    jal   x24, jal_next
jal_next:
    addi  x25, x24, 0
    NOP2
    CHECK(14, x25, jal_next)

    // A write to x0 is never forwarded.
    addi x0, x5, 1
    addi x26, x0, 0
    NOP2
    CHECK(15, x26, 0)
TEST_END

    .data
    .align 4
buf:
    .word 0, 0
