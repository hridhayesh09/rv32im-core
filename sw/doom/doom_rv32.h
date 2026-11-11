// Shared by the rv32im-core Doom port (doomgeneric + picolibc).
#ifndef DOOM_RV32_H
#define DOOM_RV32_H

#include <stdint.h>

#define CLOCK_HZ 50000000u
#define WAD_BASE 0x42000000u   // tools/upload.py --data 0x42000000 <wad>

// Hardware (rtl/soc.sv, rtl/wb_vga.sv in 8-bit mode).
#define UART_DATA      (*(volatile uint32_t *)0x10000000u)
#define UART_STATUS    (*(volatile uint32_t *)0x10000004u)
#define UART_TX_READY  (1u << 0)
#define UART_RX_VALID  (1u << 1)
#define VGA_FB         ((volatile uint8_t *)0x20000000u)   // 320 x 200, one byte per pixel
#define VGA_PALETTE256 ((volatile uint32_t *)0x10003400u)  // 256 x 12-bit colour (R 11:8 G 7:4 B 3:0)
#define VGA_FRAME      (*(volatile uint32_t *)0x10003044u)
#define GPIO_LEDS      (*(volatile uint32_t *)0x10002000u)
#define GPIO_SWITCHES  (*(volatile uint32_t *)0x10002004u)

static inline void uart_putc(char c)
{
    while (!(UART_STATUS & UART_TX_READY))
        ;
    UART_DATA = (uint8_t)c;
}

static inline int uart_try_getc(void)
{
    return (UART_STATUS & UART_RX_VALID) ? (int)(UART_DATA & 0xFF) : -1;
}

static inline uint64_t cycles64(void)
{
    uint32_t hi, lo, hi2;
    do {
        __asm__ volatile("rdcycleh %0" : "=r"(hi));
        __asm__ volatile("rdcycle %0" : "=r"(lo));
        __asm__ volatile("rdcycleh %0" : "=r"(hi2));
    } while (hi != hi2);
    return (uint64_t)hi << 32 | lo;
}

uint32_t wad_find_size(void);
int      wad_has_lump(const char *name);
extern const char *wad_name;

#endif
