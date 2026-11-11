/* Programs that run from SDRAM (through the caches): code, data and zeroed data in SDRAM at
   0x4000_0000 (up to 60 MB; the top 4 MB are left for heaps and buffers), the stack in fast
   on-chip RAM. Uses sw/crt0.S like the RAM programs. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    SDRAM (rwx) : ORIGIN = 0x40000000, LENGTH = 60M
    RAM   (rwx) : ORIGIN = 0x80000000, LENGTH = 64K
}

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text .text.*)
    } > SDRAM

    .tohost ALIGN(64) : { *(.tohost) } > SDRAM

    .data : {
        *(.rodata .rodata.*) *(.srodata .srodata.*)
        *(.data .data.*) *(.sdata .sdata.*)
    } > SDRAM

    .bss (NOLOAD) : ALIGN(4) {
        _bss_start = .;
        *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > SDRAM

    _end = .;
    _heap_start = ALIGN(16);
    _heap_end = ORIGIN(SDRAM) + 64M;
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
