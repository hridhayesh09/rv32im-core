// Minimal test environment for the official riscv-tests (replaces their env/p/riscv_test.h).
//
// A test clears the registers, installs the trap handler below, runs, and writes its result to
// tohost: 1 for pass, (failing test number << 1) | 1 for fail. Spike and the testbench both stop
// on that write.
//
// The trap handler emulates misaligned loads and stores (mcause 4 and 6), the way firmware does
// on RISC-V systems whose hardware traps on them: it saves every register, reads the faulting
// instruction (at mepc) and address (mtval), does the access one byte at a time, puts a load's
// result into the saved destination register, and returns past the instruction. Any other trap
// fails the test, reported as check number 2047.
#ifndef RISCV_TEST_H
#define RISCV_TEST_H

#define TESTNUM gp

#define RVTEST_RV64U .macro init; .endm
#define RVTEST_RV32U .macro init; .endm

#define RVTEST_TRAP_HANDLER                                                     \
    .align 2;                                                                   \
trap_vector:                                                                    \
    csrrw t0, mscratch, t0;                 /* t0 = save area, mscratch = t0 */ \
    .irp r, 1,2,3,4,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31; \
    sw x\r, \r*4(t0);                                                           \
    .endr;                                                                      \
    csrr t1, mscratch;                                                          \
    sw t1, 5*4(t0);                         /* the original t0 */              \
    sw zero, 0(t0);                                                             \
    csrr t1, mcause;                                                            \
    li t2, 4;                                                                   \
    beq t1, t2, trap_load;                                                      \
    li t2, 6;                                                                   \
    beq t1, t2, trap_store;                                                     \
    li t1, (2047 << 1) | 1;                 /* any other trap: report 2047 */  \
    la t2, tohost;                                                              \
    sw t1, 0(t2);                                                               \
trap_unexpected:                                                                \
    j trap_unexpected;                                                          \
trap_load:                                                                      \
    csrr t3, mepc;                                                              \
    lw t4, 0(t3);                           /* the faulting instruction */     \
    csrr t5, mtval;                         /* the address */                  \
    srli t6, t4, 12;                                                            \
    andi t6, t6, 7;                         /* funct3 */                       \
    andi a0, t6, 3;                                                             \
    li a1, 1;                                                                   \
    sll a1, a1, a0;                         /* size: 2 or 4 bytes */           \
    li a2, 0;                                                                   \
    li a3, 0;                                                                   \
trap_load_byte:                                                                 \
    add a4, t5, a3;                                                             \
    lbu a4, 0(a4);                                                              \
    slli a5, a3, 3;                                                             \
    sll a4, a4, a5;                                                             \
    or a2, a2, a4;                                                              \
    addi a3, a3, 1;                                                             \
    blt a3, a1, trap_load_byte;                                                 \
    li a4, 1;                                                                   \
    bne t6, a4, trap_load_done;             /* LH: sign-extend 16 bits */      \
    slli a2, a2, 16;                                                            \
    srai a2, a2, 16;                                                            \
trap_load_done:                                                                 \
    srli a4, t4, 7;                                                             \
    andi a4, a4, 31;                        /* rd */                           \
    slli a4, a4, 2;                                                             \
    add a4, a4, t0;                                                             \
    sw a2, 0(a4);                                                               \
    sw zero, 0(t0);                         /* x0 stays 0 */                   \
    j trap_return;                                                              \
trap_store:                                                                     \
    csrr t3, mepc;                                                              \
    lw t4, 0(t3);                                                               \
    csrr t5, mtval;                                                             \
    srli t6, t4, 12;                                                            \
    andi t6, t6, 3;                                                             \
    li a1, 1;                                                                   \
    sll a1, a1, t6;                         /* size: 2 or 4 bytes */           \
    srli a4, t4, 20;                                                            \
    andi a4, a4, 31;                        /* rs2 */                          \
    slli a4, a4, 2;                                                             \
    add a4, a4, t0;                                                             \
    lw a2, 0(a4);                                                               \
    li a3, 0;                                                                   \
trap_store_byte:                                                                \
    add a4, t5, a3;                                                             \
    sb a2, 0(a4);                                                               \
    srli a2, a2, 8;                                                             \
    addi a3, a3, 1;                                                             \
    blt a3, a1, trap_store_byte;                                                \
trap_return:                                                                    \
    csrr t3, mepc;                                                              \
    addi t3, t3, 4;                                                             \
    csrw mepc, t3;                                                              \
    .irp r, 1,2,3,4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31; \
    lw x\r, \r*4(t0);                                                           \
    .endr;                                                                      \
    lw t1, 5*4(t0);                                                             \
    csrw mscratch, t1;                      /* t0's value, possibly a load's */ \
    lw t1, 6*4(t0);                                                             \
    csrrw t0, mscratch, t0;                 /* t0 back, mscratch = save area */ \
    mret;

#define RVTEST_CODE_BEGIN                                                       \
    .section .text.init;                                                        \
    .align 6;                                                                   \
    .globl _start;                                                              \
_start:                                                                         \
    .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,                             \
            17,18,19,20,21,22,23,24,25,26,27,28,29,30,31;                       \
    li x\r, 0;                                                                  \
    .endr;                                                                      \
    la t0, trap_vector;                                                         \
    csrw mtvec, t0;                                                             \
    la t0, trap_save_area;                                                      \
    csrw mscratch, t0;                                                          \
    li t0, 0;                                                                   \
    j trap_handler_end;                                                         \
    RVTEST_TRAP_HANDLER                                                         \
trap_handler_end:                                                               \
    init;                                                                       \
    .pushsection .data;                                                         \
    .align 4;                                                                   \
trap_save_area: .space 128;                                                     \
    .popsection;

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
