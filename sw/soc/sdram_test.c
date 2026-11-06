// SDRAM test from the CPU: words, halfwords and bytes across the whole 64 MB, an address test
// (each power-of-two address gets its own value, which catches address lines that are stuck or
// shorted together), and a timed block copy.
#include "soc.h"

#define SDRAM_BASE 0x40000000u
#define SDRAM_SIZE (64u << 20)

static volatile uint32_t *const sdram32 = (volatile uint32_t *)SDRAM_BASE;

static uint32_t seed = 1;
static uint32_t next_random(void)
{
    seed = seed * 1103515245u + 12345u;
    return seed;
}

int main(void)
{
    int errors = 0;
    printf("SDRAM test\n");

    // 1. Address lines: write a different value at every power-of-two word offset, then read
    //    all of them back. If two address lines were shorted, a later write would overwrite an
    //    earlier one.
    for (uint32_t off = 1; off < SDRAM_SIZE / 4; off <<= 1)
        sdram32[off] = off ^ 0xA5A5A5A5u;
    sdram32[0] = 0x12345678u;
    for (uint32_t off = 1; off < SDRAM_SIZE / 4; off <<= 1) {
        if (sdram32[off] != (off ^ 0xA5A5A5A5u)) {
            printf("address line error at word offset 0x%x\n", off);
            errors++;
        }
    }
    printf("address lines: %s\n", errors ? "FAIL" : "ok");

    // 2. Random words across the whole chip.
    seed = 1;
    for (int i = 0; i < 256; i++) {
        uint32_t off = (next_random() >> 6) & (SDRAM_SIZE / 4 - 1);
        sdram32[off] = off * 2654435761u;
    }
    seed = 1;
    for (int i = 0; i < 256; i++) {
        uint32_t off = (next_random() >> 6) & (SDRAM_SIZE / 4 - 1);
        if (sdram32[off] != off * 2654435761u)
            errors++;
    }
    printf("random words: %s\n", errors ? "FAIL" : "ok");

    // 3. Byte and halfword writes (the byte masks).
    volatile uint8_t *b = (volatile uint8_t *)(SDRAM_BASE + 0x1000);
    volatile uint16_t *h = (volatile uint16_t *)(SDRAM_BASE + 0x2000);
    sdram32[0x1000 / 4] = 0;
    b[0] = 0x11; b[1] = 0x22; b[2] = 0x33; b[3] = 0x44;
    h[0] = 0xBEEF; h[1] = 0xCAFE;
    if (sdram32[0x1000 / 4] != 0x44332211u || sdram32[0x2000 / 4] != 0xCAFEBEEFu || b[2] != 0x33)
        errors++;
    printf("bytes and halfwords: %s\n", errors ? "FAIL" : "ok");

    // 4. Timed copy of 1 KB from on-chip RAM to SDRAM and back.
    static uint32_t src[256], dst[256];
    for (int i = 0; i < 256; i++)
        src[i] = next_random();
    uint64_t t0 = timer_cycles();
    for (int i = 0; i < 256; i++)
        sdram32[0x10000 + i] = src[i];
    uint64_t t1 = timer_cycles();
    for (int i = 0; i < 256; i++)
        dst[i] = sdram32[0x10000 + i];
    uint64_t t2 = timer_cycles();
    for (int i = 0; i < 256; i++)
        if (dst[i] != src[i])
            errors++;
    printf("copy: %s, write %u cycles, read %u cycles for 256 words\n",
           errors ? "FAIL" : "ok", (unsigned)(t1 - t0), (unsigned)(t2 - t1));

    printf(errors ? "SDRAM FAIL\n" : "SDRAM PASS\n");
    printf("DONE\n");
    return errors;
}
