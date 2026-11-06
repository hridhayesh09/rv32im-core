#include "soc.h"

// Segments for 0-F: bit 0 = a (top), then b, c, d, e, f, g (middle) clockwise from the top.
static const uint8_t SEGMENTS[16] = {
    0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07,
    0x7F, 0x6F, 0x77, 0x7C, 0x39, 0x5E, 0x79, 0x71,
};

void hex_show_hex(uint32_t value)
{
    for (int i = 0; i < 6; i++, value >>= 4)
        GPIO_HEX(i) = SEGMENTS[value & 0xF];
}

void hex_show_dec(uint32_t value)
{
    for (int i = 0; i < 6; i++) {
        // Blank leading zeros, but always show the last digit.
        GPIO_HEX(i) = (value || i == 0) ? SEGMENTS[value % 10] : 0;
        value /= 10;
    }
}
