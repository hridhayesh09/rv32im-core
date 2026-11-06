// Minimal test environment for the official riscv-tests (replaces their env/p/riscv_test.h).
//
// The standard environment sets up machine-mode CSRs and trap handlers and ends a test with
// ECALL. This core has no CSRs yet, so here a test just clears the registers, runs, and writes
// its result straight to tohost: 1 for pass, (failing test number << 1) | 1 for fail.
// Spike and the testbench both stop on that write.
#ifndef RISCV_TEST_H
#define RISCV_TEST_H

#define TESTNUM gp

#define RVTEST_RV64U .macro init; .endm
#define RVTEST_RV32U .macro init; .endm

#define RVTEST_CODE_BEGIN                                       \
    .section .text.init;                                        \
    .align 6;                                                   \
    .globl _start;                                              \
_start:                                                         \
    .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,             \
            17,18,19,20,21,22,23,24,25,26,27,28,29,30,31;       \
    li x\r, 0;                                                  \
    .endr;                                                      \
    init;

#define RVTEST_CODE_END unimp

#define RVTEST_PASS                                             \
    fence;                                                      \
    li TESTNUM, 1;                                              \
    la t5, tohost;                                              \
    sw TESTNUM, 0(t5);                                          \
1:  j 1b;

#define RVTEST_FAIL                                             \
    fence;                                                      \
1:  beqz TESTNUM, 1b;                                           \
    sll TESTNUM, TESTNUM, 1;                                    \
    or TESTNUM, TESTNUM, 1;                                     \
    la t5, tohost;                                              \
    sw TESTNUM, 0(t5);                                          \
1:  j 1b;

#define RVTEST_DATA_BEGIN                                       \
    .pushsection .tohost, "aw", @progbits;                      \
    .align 6; .globl tohost;   tohost:   .dword 0;              \
    .align 6; .globl fromhost; fromhost: .dword 0;              \
    .popsection;                                                \
    .align 4; .globl begin_signature; begin_signature:

#define RVTEST_DATA_END .align 4; .globl end_signature; end_signature:

#endif
