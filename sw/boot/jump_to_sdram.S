// Minimal boot ROM for simulation: jump straight to a program preloaded into SDRAM.
    .section .text.init
    .globl _start
_start:
    lui  t0, 0x40000
    jr   t0
