// Exceptions and CSRs: ECALL, EBREAK, an illegal instruction, a misaligned load, store and jump
// each trap to mtvec with the right mcause, mepc and mtval; the handler returns with MRET past
// the instruction. Plus every CSR instruction form, MRET's effect on mstatus, and minstret.
// Spike traps the same way, so lockstep checks every step (handler included).
#include "common.h"

// The handler stores mcause, mepc and mtval in s2, s3, s4, then returns past the instruction.
#define EXPECT_TRAP(n, cause, insn_label) \
    li gp, n; NOP2; CHECK(n, s2, cause); LI(x31, insn_label); NOP2; bne s3, x31, fail

TEST_BEGIN
    la   t0, handler
    csrw mtvec, t0
    csrr t1, mtvec
    NOP2
    CHECK(1, t1, handler)

    // ECALL and EBREAK.
e1: ecall
    EXPECT_TRAP(2, 11, e1)
e2: ebreak
    EXPECT_TRAP(3, 3, e2)
    CHECK(4, s4, e2)                       // EBREAK: mtval = its address

    // An illegal instruction (all zeros): mtval holds the instruction.
e3: .word 0x00000000
    EXPECT_TRAP(5, 2, e3)
    CHECK(6, s4, 0)
    // A CSR that doesn't exist is illegal too.
e4: csrr t1, 0x7c0
    EXPECT_TRAP(7, 2, e4)

    // Misaligned load and store: mtval = the address.
    la   s0, data
e5: lw   t1, 1(s0)
    EXPECT_TRAP(8, 4, e5)
    addi t2, s0, 1
    NOP2
    bne  s4, t2, fail
e6: sh   t1, 3(s0)
    EXPECT_TRAP(9, 6, e6)

    // Misaligned jump target (bit 1 set): mcause 0, mepc = the jump, mtval = the target.
    la   t0, jump_target
e7: jalr x0, 2(t0)
    EXPECT_TRAP(10, 0, e7)

    // CSR instructions: write, set, clear, and their immediate forms, on mscratch.
    li     t1, 0x0f0f
    csrrw  t2, mscratch, t1                // t2 = old (0)
    li     t4, 0x3000
    csrrs  t3, mscratch, t4                // t3 = 0x0f0f, mscratch = 0x3f0f
    csrrc  t5, mscratch, t1                // t5 = 0x3f0f, mscratch = 0x3000
    csrrwi t6, mscratch, 21                // t6 = 0x3000, mscratch = 21
    csrrsi a0, mscratch, 8                 // a0 = 21, mscratch = 29
    csrrci a1, mscratch, 1                 // a1 = 29, mscratch = 28
    csrr   a2, mscratch                    // a2 = 28
    NOP2
    CHECK(11, t2, 0)
    CHECK(12, t3, 0x0f0f)
    CHECK(13, t5, 0x3f0f)
    CHECK(14, t6, 0x3000)
    CHECK(15, a0, 21)
    CHECK(16, a1, 29)
    CHECK(17, a2, 28)

    // Read-only CSRs: reading is fine, writing is illegal.
    csrr a3, mhartid
    csrr a4, misa
    NOP2
    CHECK(18, a3, 0)
e8: csrw mhartid, t1
    EXPECT_TRAP(19, 2, e8)

    // mstatus: a trap copies MIE into MPIE and clears MIE; MRET copies MPIE back.
    csrsi mstatus, 8                       // MIE = 1
e9: ecall
    csrr a5, mstatus                       // after MRET: MIE = 1 (restored), MPIE = 1
    NOP2
    andi a5, a5, 0x88
    CHECK(20, a5, 0x88)
    CHECK(21, s5, 0x80)                    // inside the handler: MIE = 0, MPIE = 1
    csrci mstatus, 8

    // minstret counts retired instructions exactly: set it, run 5 instructions, read it.
    csrw minstret, x0
    nop
    nop
    nop
    nop
    nop
    csrr a6, minstret
    NOP2
    CHECK(22, a6, 5)
TEST_END

handler:
    csrr s2, mcause
    csrr s3, mepc
    csrr s4, mtval
    csrr s5, mstatus
    andi s5, s5, 0x88
    addi s6, s3, 4
    csrw mepc, s6
    mret

    .align 4
jump_target:
    nop
    nop

    .data
    .align 4
data:
    .word 0x04030201, 0x08070605
