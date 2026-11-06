// A small printf for the UART: %c %s %d %u %x %X %p %%, with an optional 0 flag and width.
#include <stdarg.h>
#include "soc.h"

static int put_number(uint32_t value, unsigned base, int negative, int width, char pad, int upper)
{
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    char buf[12];
    int n = 0, count = 0;
    do {
        buf[n++] = digits[value % base];
        value /= base;
    } while (value);
    if (negative)
        width--;
    if (negative && pad == '0') {
        uart_putc('-');
        count++;
    }
    for (int i = n; i < width; i++, count++)
        uart_putc(pad);
    if (negative && pad != '0') {
        uart_putc('-');
        count++;
    }
    while (n)
        uart_putc(buf[--n]), count++;
    return count;
}

int printf(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    int count = 0;
    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            uart_putc(*fmt);
            count++;
            continue;
        }
        fmt++;
        char pad = ' ';
        int width = 0;
        if (*fmt == '0') {
            pad = '0';
            fmt++;
        }
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');
        switch (*fmt) {
        case 'c':
            uart_putc((char)va_arg(args, int));
            count++;
            break;
        case 's': {
            const char *s = va_arg(args, const char *);
            int len = 0;
            while (s[len])
                len++;
            for (int i = len; i < width; i++, count++)
                uart_putc(' ');
            uart_puts(s);
            count += len;
            break;
        }
        case 'd': {
            int v = va_arg(args, int);
            count += put_number(v < 0 ? -(uint32_t)v : (uint32_t)v, 10, v < 0, width, pad, 0);
            break;
        }
        case 'u':
            count += put_number(va_arg(args, uint32_t), 10, 0, width, pad, 0);
            break;
        case 'x':
        case 'X':
            count += put_number(va_arg(args, uint32_t), 16, 0, width, pad, *fmt == 'X');
            break;
        case 'p':
            uart_puts("0x");
            count += 2 + put_number((uint32_t)va_arg(args, void *), 16, 0, 8, '0', 0);
            break;
        case '%':
            uart_putc('%');
            count++;
            break;
        default:   // unknown conversion (or the string ended after %): print it as is
            uart_putc('%');
            count++;
            if (!*fmt)
                goto done;
            uart_putc(*fmt);
            count++;
        }
    }
done:
    va_end(args);
    return count;
}
