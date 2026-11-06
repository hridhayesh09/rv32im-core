// Shared startup and pass/fail for the hand-written assembly tests.
//
// A test sets gp (x3) to the number of the check it is about to do. On a failed check it
// writes (gp << 1) | 1 to tohost; at the end it writes 1. The testbench and Spike both stop
// when tohost is written. NOP2 separates dependent instructions in tests meant to run
// without forwarding.

#define NOP2 nop; nop

// Load a 32-bit constant, padded so it works without forwarding.
#define LI(rd, v) lui rd, %hi(v); NOP2; addi rd, rd, %lo(v); NOP2

// Check number n: register r must equal v (r must be ready, i.e. written 3+ instructions ago).
#define CHECK(n, r, v) li gp, n; LI(x31, v); bne r, x31, fail

#define TEST_BEGIN              \
    .section .text.init;        \
    .globl _start;              \
_start:                         \
    li gp, 0;

#define TEST_END                \
    lui  t5, %hi(tohost);       \
    li   t6, 1;                 \
    NOP2;                       \
    addi t5, t5, %lo(tohost);   \
    NOP2;                       \
    sw   t6, 0(t5);             \
1:  j 1b;                       \
fail:                           \
    lui  t5, %hi(tohost);       \
    slli t6, gp, 1;             \
    NOP2;                       \
    addi t5, t5, %lo(tohost);   \
    ori  t6, t6, 1;             \
    NOP2;                       \
    sw   t6, 0(t5);             \
2:  j 2b;                       \
    .section .tohost, "aw", @progbits; \
    .align 6; .globl tohost;   tohost:   .word 0, 0; \
    .align 6; .globl fromhost; fromhost: .word 0, 0;
