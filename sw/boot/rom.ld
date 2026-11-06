/* Boot ROM image: code and read-only data in ROM at the reset address; variables and the stack
   in on-chip RAM. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 8K
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 64K
}

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text .text.*)
        *(.rodata .rodata.*) *(.srodata .srodata.*)
    } > ROM

    /* No initialized variables allowed in ROM code (nothing copies them to RAM). */
    .data : { *(.data .data.*) *(.sdata .sdata.*) } > RAM
    ASSERT(SIZEOF(.data) == 0, "boot ROM code must not have initialized variables")

    /* Zero-initialized variables live at the top of RAM, below the stack, away from the
       program the bootloader loads at the start of RAM. */
    .bss 0x8000C000 (NOLOAD) : {
        _bss_start = .;
        *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    }

    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
