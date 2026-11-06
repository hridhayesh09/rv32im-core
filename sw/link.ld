/* Memory map for simulation and Spike: one RAM region at 0x80000000 (Spike's default). */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 64K
}

SECTIONS
{
    .text : {
        *(.text.init)       /* _start first, at the reset address */
        *(.text .text.*)
    } > RAM

    /* tohost/fromhost: writing tohost ends a simulation (Spike's HTIF convention). */
    .tohost ALIGN(64) : { *(.tohost) } > RAM

    .data : { *(.rodata .rodata.*) *(.data .data.*) *(.sdata .sdata.*) } > RAM
    .bss  : { *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON) } > RAM

    _end = .;
}
