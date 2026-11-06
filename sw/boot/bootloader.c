// UART bootloader, in the boot ROM. Receives a program over the serial port into on-chip RAM
// and runs it, so new programs don't need an FPGA rebuild.
//
// Protocol (host side: tools/upload.py), all numbers little-endian:
//   host -> "BOOT", length (4 bytes), the program bytes, CRC-32 of the program (4 bytes)
//   board -> "OK\n" and runs the program, or "ERR ...\n" and waits again
// Sending a single 'R' instead reruns the program already in RAM (e.g. after pressing reset).
#include "soc.h"

#define RAM_BASE    0x80000000u
#define MAX_PROGRAM (48u << 10)   // above that: the bootloader's own variables and stack

static uint32_t read_u32(void)
{
    uint32_t value = 0;
    for (int i = 0; i < 4; i++)
        value |= (uint32_t)uart_getc() << (8 * i);
    return value;
}

// CRC-32 (the one zlib, Ethernet and PNG use), bit by bit: slow, but small for a ROM.
static uint32_t crc32(const volatile uint8_t *p, uint32_t n)
{
    uint32_t crc = ~0u;
    while (n--) {
        crc ^= *p++;
        for (int k = 0; k < 8; k++)
            crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1));
    }
    return ~crc;
}

static void run_program(void)
{
    uart_puts("starting program\n");
    GPIO_LEDS = 0;
    __asm__ volatile("fence.i");   // the new code was written with stores; fetch must see it
    ((void (*)(void))RAM_BASE)();
}

int main(void)
{
    uart_puts("\nrv32im-core bootloader\n");
    for (;;) {
        GPIO_LEDS = 1;             // LED0: waiting for a program
        uart_puts("ready\n");

        // Wait for "BOOT" (or 'R').
        const char *magic = "BOOT";
        int matched = 0;
        while (matched < 4) {
            int c = uart_getc();
            if (c == 'R' && matched == 0)
                run_program();
            if (c == magic[matched])
                matched++;
            else
                matched = (c == 'B');
        }

        uint32_t length = read_u32();
        if (length == 0 || length > MAX_PROGRAM) {
            uart_puts("ERR size\n");
            continue;
        }

        // Receive straight into RAM. Nothing else in this loop: at 115200 baud a byte arrives
        // every ~4,300 cycles, and the UART only holds one.
        volatile uint8_t *dst = (volatile uint8_t *)RAM_BASE;
        for (uint32_t i = 0; i < length; i++)
            dst[i] = (uint8_t)uart_getc();

        uint32_t expected = read_u32();
        if (crc32(dst, length) != expected) {
            uart_puts("ERR crc\n");
            continue;
        }
        uart_puts("OK\n");
        run_program();
    }
}
