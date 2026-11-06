// Boot ROM startup: clear registers, set the stack (top of RAM), zero .bss (in RAM, see
// rom.ld), call main. main never returns; if it did, loop.
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
3:  j    3b
