#include "soc.h"

void uart_putc(char c)
{
    if (c == '\n')
        uart_putc('\r');   // terminals expect CR LF
    while (!(UART_STATUS & UART_TX_READY))
        ;
    UART_DATA = (uint8_t)c;
}

void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

int uart_try_getc(void)
{
    if (UART_STATUS & UART_RX_VALID)
        return UART_DATA & 0xFF;
    return -1;
}

int uart_getc(void)
{
    int c;
    while ((c = uart_try_getc()) < 0)
        ;
    return c;
}
