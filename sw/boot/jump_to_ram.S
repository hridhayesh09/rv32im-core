// Minimal boot ROM: jump straight to the program in on-chip RAM (used in simulation when the
// program is preloaded into RAM, and until the bootloader replaces it).
    .section .text.init
    .globl _start
_start:
    lui  t0, 0x80000
    jr   t0
