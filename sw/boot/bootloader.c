// UART bootloader, in the boot ROM. Receives data and programs over the serial port, so new
// programs don't need an FPGA rebuild.
//
// Commands (host side: tools/upload.py), numbers little-endian, each followed by a CRC-32 of
// the bytes sent:
//   "BOOT", length, program bytes, crc   -> stored at 0x8000_0000, "OK", and run
//   "LOAD", address, length, bytes, crc  -> stored at address (SDRAM, or RAM below 48 KB),
//                                           "OK", and wait for the next command
//   "BAUD", divisor                      -> "OK" at the current rate, then the UART switches to
//                                           50 MHz / divisor baud (e.g. 25: 2 Mbaud)
//   'R' as the first byte after "ready"  -> run the program already in RAM again
// A bad length, address or CRC gets "ERR ..." and the bootloader waits again.
#include "soc.h"

#define RAM_BASE    0x80000000u
#define MAX_PROGRAM (48u << 10)   // above that: the bootloader's own variables and stack
#define SDRAM_BASE  0x40000000u
#define SDRAM_SIZE  (64u << 20)

#define CMD_BOOT 0x424F4F54u      // "BOOT", as the last 4 bytes received
#define CMD_LOAD 0x4C4F4144u      // "LOAD"
#define CMD_BAUD 0x42415544u      // "BAUD"

static uint32_t read_u32(void)
{
    uint32_t value = 0;
    for (int i = 0; i < 4; i++)
        value |= (uint32_t)uart_getc() << (8 * i);
    return value;
}

// CRC-32 (the one zlib, Ethernet and PNG use), one table lookup per byte. The 1 KB table is
// computed at start-up (in RAM, not the ROM), so a 28 MB Doom WAD is checked quickly.
static uint32_t crc_table[256];

static void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++)
            c = (c >> 1) ^ (0xEDB88320u & -(c & 1));
        crc_table[i] = c;
    }
}

static uint32_t crc32(const volatile uint8_t *p, uint32_t n)
{
    uint32_t crc = ~0u;
    while (n--)
        crc = crc_table[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

static int fits(uint32_t addr, uint32_t length, uint32_t base, uint32_t size)
{
    return length <= size && addr >= base && addr - base <= size - length;
}

// Receive length bytes into dst and check the CRC that follows. Nothing else in the loop: at
// 2 Mbaud a byte arrives every 250 cycles (the UART's FIFO covers cache misses).
static int receive(volatile uint8_t *dst, uint32_t length)
{
    for (uint32_t i = 0; i < length; i++)
        dst[i] = (uint8_t)uart_getc();
    uint32_t expected = read_u32();
    if (crc32(dst, length) != expected) {
        uart_puts("ERR crc\n");
        return 0;
    }
    uart_puts("OK\n");
    return 1;
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
    // The first SDRAM access waits for the controller's 200 us power-up sequence. Do it now, so
    // a LOAD into SDRAM can't stall while UART bytes keep arriving (the UART holds only one).
    (void)*(volatile uint32_t *)SDRAM_BASE;
    crc_init();
    uart_puts("\nrv32im-core bootloader\n");
    for (;;) {
        GPIO_LEDS = 1;             // LED0: waiting
        uart_puts("ready\n");

        // Wait for a command: the last 4 bytes received spell BOOT or LOAD.
        uint32_t last4 = 0;
        for (int n = 0;; n++) {
            int c = uart_getc();
            if (n == 0 && c == 'R')
                run_program();
            last4 = last4 << 8 | (uint32_t)c;
            if (last4 == CMD_BOOT || last4 == CMD_LOAD || last4 == CMD_BAUD)
                break;
        }

        if (last4 == CMD_BAUD) {
            uint32_t divisor = read_u32();
            if (divisor < 8 || divisor > 0xFFFF) {
                uart_puts("ERR baud\n");
                continue;
            }
            uart_puts("OK\n");
            while (!(UART_STATUS & UART_TX_READY))
                ;                  // the last byte of "OK" leaves at the old rate
            UART_DIVISOR = divisor;
        } else if (last4 == CMD_BOOT) {
            uint32_t length = read_u32();
            if (length == 0 || length > MAX_PROGRAM) {
                uart_puts("ERR size\n");
                continue;
            }
            if (receive((volatile uint8_t *)RAM_BASE, length))
                run_program();
        } else {
            uint32_t addr = read_u32();
            uint32_t length = read_u32();
            if (length == 0 || !(fits(addr, length, SDRAM_BASE, SDRAM_SIZE) ||
                                 fits(addr, length, RAM_BASE, MAX_PROGRAM))) {
                uart_puts("ERR address\n");
                continue;
            }
            GPIO_LEDS = 2;         // LED1: receiving data
            receive((volatile uint8_t *)addr, length);
        }
    }
}
