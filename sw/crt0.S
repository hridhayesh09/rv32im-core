// C runtime startup: the first code that runs, before main.
//
// 1. Clear every register, so the core and Spike start from the same state.
// 2. Point the stack pointer at the end of RAM.
// 3. Zero the .bss section (C guarantees uninitialized globals start at 0).
// 4. Call main.
// 5. Report main's return value through tohost: 0 -> pass (1), n -> fail ((n << 1) | 1).

    .section .text.init
    .globl _start
_start:
    .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li x\r, 0
    .endr

    la   sp, _stack_top

    la   t0, _bss_start
    la   t1, _bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:
    call main

    li   t0, 1
    beqz a0, 3f
    slli t0, a0, 1
    ori  t0, t0, 1
3:  la   t1, tohost
    sw   t0, 0(t1)
4:  j    4b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .align 6
    .globl fromhost
fromhost: .dword 0
