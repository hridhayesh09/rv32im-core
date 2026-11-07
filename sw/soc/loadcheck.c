// Prints the 16 bytes at SDRAM 0x4000_1000: used to check the bootloader's LOAD command.
#include "soc.h"

int main(void)
{
    const volatile char *p = (const volatile char *)0x40001000u;
    printf("loaded: ");
    for (int i = 0; i < 16; i++)
        uart_putc(p[i]);
    printf("\nDONE\n");
    return 0;
}
