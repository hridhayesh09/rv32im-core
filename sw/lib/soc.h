// Register map of the SoC's peripherals (see rtl/soc.sv) and small helpers to use them.
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define REG(addr) (*(volatile uint32_t *)(addr))

// SDRAM (64 MB): through the caches when the SoC has them, or the same memory never cached.
#ifndef SDRAM_BASE
#define SDRAM_BASE     0x40000000u
#endif
#define SDRAM_UNCACHED 0x50000000u

// UART
#define UART_BASE      0x10000000u
#define UART_DATA      REG(UART_BASE + 0x0)
#define UART_STATUS    REG(UART_BASE + 0x4)
#define UART_DIVISOR   REG(UART_BASE + 0x8)
#define UART_TX_READY  (1u << 0)
#define UART_RX_VALID  (1u << 1)

// Timer
#define TIMER_BASE     0x10001000u
#define TIMER_TIME_LO  REG(TIMER_BASE + 0x00)
#define TIMER_TIME_HI  REG(TIMER_BASE + 0x04)
#define TIMER_CMP_LO   REG(TIMER_BASE + 0x08)
#define TIMER_CMP_HI   REG(TIMER_BASE + 0x0C)
#define TIMER_STATUS   REG(TIMER_BASE + 0x10)
#define TIMER_CLK_HZ   REG(TIMER_BASE + 0x14)

// GPIO
#define GPIO_BASE      0x10002000u
#define GPIO_LEDS      REG(GPIO_BASE + 0x00)
#define GPIO_SWITCHES  REG(GPIO_BASE + 0x04)
#define GPIO_KEYS      REG(GPIO_BASE + 0x08)
#define GPIO_HEX(n)    REG(GPIO_BASE + 0x10 + 4 * (n))   // n = 0..5, rightmost is 0

// uart.c
void uart_putc(char c);
void uart_puts(const char *s);
int  uart_getc(void);             // waits for a byte
int  uart_try_getc(void);         // -1 if nothing received

// printf.c: %c %s %d %u %x %X %p %%, with optional 0 flag and width (e.g. %08x)
int printf(const char *fmt, ...);

// timer.c
uint64_t timer_cycles(void);
void     delay_us(uint32_t us);
void     delay_ms(uint32_t ms);

// gpio.c
void hex_show_hex(uint32_t value);  // the low 24 bits as 6 hex digits
void hex_show_dec(uint32_t value);  // up to 999999 in decimal

#endif
