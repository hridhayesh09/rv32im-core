// Jump straight to a program at the start of SDRAM: as a boot ROM in simulation (program
// preloaded into SDRAM), or as a tiny program in RAM on the board (tools/build_sw.py).
    .section .text.init
    .globl _start
_start:
    lui  t0, 0x40000
    jr   t0
