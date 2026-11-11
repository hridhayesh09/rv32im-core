// Branch predictor stress test. Predictions only change timing, so every check here is about
// results; the lockstep run also compares every retired instruction with Spike. Covers:
//   1. a branch with a repeating taken/not-taken pattern (what gshare is for)
//   2. recursion deeper than the return-address stack (old entries are overwritten)
//   3. indirect calls and jumps whose target changes every time
//   4. calls and returns through t0 instead of ra
//   5. stale BTB entries: a jump is overwritten (FENCE.I) by a divide, then by a load.
//      The BTB still says "jump" for that PC, so EX must notice the instruction isn't
//      a branch (after the divide finishes) and fetch PC+4 instead.
#include "common.h"

TEST_BEGIN
    la   sp, stack_top
    j    main

// ---- functions
sum:                          // a0 = a0 + (a0-1) + ... + 1, recursively
    addi sp, sp, -8
    sw   ra, 4(sp)
    sw   a0, 0(sp)
    beqz a0, 1f
    addi a0, a0, -1
    call sum
    lw   t1, 0(sp)
    add  a0, a0, t1
    j    2f
1:  li   a0, 0
2:  lw   ra, 4(sp)
    addi sp, sp, 8
    ret

add1:   addi s1, s1, 1
        ret
add10:  addi s1, s1, 10
        ret
add100: addi s1, s1, 100
        ret

func_t0:                      // called with jal t0, returns with jr t0
    addi s2, s2, 1
    jr   t0

run5:                         // 4 times: the instruction at patch5, then maybe count s3
    li   s4, 4
loop5:
patch5:
    j    skip5                // replaced by the test (a jump: always predicted taken)
    addi s3, s3, 1
skip5:
    addi s4, s4, -1
    bnez s4, loop5
    ret

tmpl_div:                     // instruction templates (never executed here)
    div  s5, s6, s7
tmpl_lw:
    lw   s9, 0(sp)

handlers:                     // jump table for part 3
    .word add1, add10, add100
jtargets:
    .word jt0, jt1, jt2

main:
    // ---- 1. taken every third time, 300 iterations
    li   t0, 300
    li   t2, 0
    li   t3, 0
    li   t4, 3
loop1:
    addi t2, t2, 1
    bne  t2, t4, 1f
    li   t2, 0
    addi t3, t3, 1
1:  addi t0, t0, -1
    bnez t0, loop1
    CHECK(1, t3, 100)

    // ---- 2. recursion: sum(5) + sum(12) + sum(3) = 15 + 78 + 6
    li   a0, 5
    call sum
    mv   s0, a0
    li   a0, 12
    call sum
    add  s0, s0, a0
    li   a0, 3
    call sum
    add  s0, s0, a0
    CHECK(2, s0, 99)

    // ---- 3a. indirect calls through a table, target changes every time: 10 x (1 + 10 + 100)
    li   s1, 0
    li   t0, 30
    li   t2, 0               // index 0..2
    la   t4, handlers
loop3:
    slli t3, t2, 2
    add  t3, t3, t4
    lw   t3, 0(t3)
    jalr ra, 0(t3)
    addi t2, t2, 1
    li   t3, 3
    bne  t2, t3, 1f
    li   t2, 0
1:  addi t0, t0, -1
    bnez t0, loop3
    CHECK(3, s1, 1110)

    // ---- 3b. indirect jumps (no link) through a table: 10 x (1 + 2 + 4)
    li   s1, 0
    li   t0, 30
    li   t2, 0
    la   t4, jtargets
loop3b:
    slli t3, t2, 2
    add  t3, t3, t4
    lw   t3, 0(t3)
    jr   t3
jt0: addi s1, s1, 1
    j    jdone
jt1: addi s1, s1, 2
    j    jdone
jt2: addi s1, s1, 4
jdone:
    addi t2, t2, 1
    li   t3, 3
    bne  t2, t3, 1f
    li   t2, 0
1:  addi t0, t0, -1
    bnez t0, loop3b
    CHECK(4, s1, 70)

    // ---- 4. calls through t0
    li   s2, 0
    li   t2, 20
loop4:
    jal  t0, func_t0
    addi t2, t2, -1
    bnez t2, loop4
    CHECK(5, s2, 20)

    // ---- 5. stale BTB entries
    li   s3, 0
    li   s6, 100
    li   s7, 7
    li   t1, 1234
    sw   t1, 0(sp)
    call run5                 // patch5 is a jump: s3 stays 0
    la   t1, patch5
    lw   t2, tmpl_div
    sw   t2, 0(t1)
    fence.i
    call run5                 // patch5 is a divide: s3 += 4
    la   t1, patch5
    lw   t2, tmpl_lw
    sw   t2, 0(t1)
    fence.i
    call run5                 // patch5 is a load: s3 += 4
    CHECK(6, s3, 8)
    CHECK(7, s5, 14)
    CHECK(8, s9, 1234)

    j    done

    .align 4
    .space 512
stack_top:
    .space 16                 // part 5 stores at 0(sp)

done:
TEST_END
