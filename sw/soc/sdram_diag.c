// SDRAM fault finder for the cached SoC: separates the controller's two paths. Uncached accesses
// (0x5...) are single words over the bus; cached accesses (0x4...) move 16-byte lines in bursts
// (a miss reads a line, an eviction or FENCE.I writes a dirty line back). Each region is 16 KB,
// bigger than the 4 KB data cache.
#include "soc.h"

#define N 4096
#define CACHED(off)   ((volatile uint32_t *)(SDRAM_BASE + (off)))
#define UNCACHED(off) ((volatile uint32_t *)(SDRAM_UNCACHED + (off)))

static uint32_t pattern(uint32_t i, uint32_t seed)
{
    return (i * 2654435761u) ^ (seed * 0x01010101u) ^ (i << 16);
}

static int check(const char *name, volatile uint32_t *p, uint32_t seed)
{
    int errors = 0;
    for (uint32_t i = 0; i < N; i++) {
        uint32_t got = p[i], want = pattern(i, seed);
        if (got != want) {
            if (errors < 8)
                printf("  word %u: got %08x want %08x\n", i, got, want);
            errors++;
        }
    }
    printf("%s: %d errors\n", name, errors);
    return errors;
}

static void evict(void)   // read 16 KB elsewhere through the cache: every line is replaced
{
    uint32_t sum = 0;
    for (uint32_t i = 0; i < N; i++)
        sum += CACHED(0x800000)[i];
    (void)sum;
}

int main(void)
{
    int total = 0;
    printf("SDRAM diag\n");

    for (uint32_t i = 0; i < N; i++) UNCACHED(0x100000)[i] = pattern(i, 1);
    total += check("1 words: uncached write, uncached read", UNCACHED(0x100000), 1);

    for (uint32_t i = 0; i < N; i++) UNCACHED(0x200000)[i] = pattern(i, 2);
    evict();
    total += check("2 burst reads: uncached write, cached read", CACHED(0x200000), 2);

    for (uint32_t i = 0; i < N; i++) CACHED(0x300000)[i] = pattern(i, 3);
    __asm__ volatile("fence.i" ::: "memory");   // writes every dirty line back
    total += check("3 burst writes: cached write, uncached read", UNCACHED(0x300000), 3);

    for (uint32_t i = 0; i < N; i++) CACHED(0x400000)[i] = pattern(i, 4);
    evict();
    total += check("4 both: cached write, evict, cached read", CACHED(0x400000), 4);

    printf(total ? "DIAG FAIL\n" : "DIAG PASS\n");
    printf("DONE\n");
    return 0;
}
