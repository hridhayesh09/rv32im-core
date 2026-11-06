// First program on the SoC: prints over the UART, times a computation with the timer, reads
// the switches, and lights the LEDs and 7-segment displays.
#include "soc.h"

static unsigned fib(unsigned n)
{
    unsigned a = 0, b = 1;
    while (n--) {
        unsigned t = a + b;
        a = b;
        b = t;
    }
    return a;
}

int main(void)
{
    printf("Hello from rv32im-core!\n");

    uint64_t start = timer_cycles();
    unsigned f = fib(30);
    uint64_t cycles = timer_cycles() - start;
    printf("fib(30) = %u, %u cycles\n", f, (unsigned)cycles);

    printf("switches = 0x%03x\n", GPIO_SWITCHES);
    printf("printf check: [%5d] [%3d] [%08x] [%s] [%c] [%%]\n", -42, 7, 0xBEEF, "ok", 'Z');

    GPIO_LEDS = 0x2AA;
    hex_show_hex(0xC0FFEE);
    printf("DONE\n");
    return 0;
}
