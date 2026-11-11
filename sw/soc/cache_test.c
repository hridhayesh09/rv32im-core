// Runs from SDRAM through the caches (link with sw/sdram.ld): sums an array bigger than the data
// cache several times, writes results back, checks them, and prints the cache counters.
#include "perf.h"
#include "soc.h"

#define N 4096                    // 16 KB of data: larger than the data cache

static uint32_t data[N];

int main(void)
{
    uint32_t ia0 = PERF_ICACHE_HITS, im0 = PERF_ICACHE_MISS;
    uint32_t da0 = PERF_DCACHE_HITS, dm0 = PERF_DCACHE_MISS;
    uint32_t c0 = PERF_CYCLES, n0 = PERF_INSTRET;

    for (int i = 0; i < N; i++)
        data[i] = i * 2654435761u;
    uint32_t sum = 0;
    for (int pass = 0; pass < 3; pass++)
        for (int i = 0; i < N; i++)
            sum += data[i] ^ pass;
    for (int i = 0; i < N; i += 4)
        data[i] += 1;              // dirty every line again
    uint32_t check = 0;
    for (int i = 0; i < N; i++)
        check += data[i];

    uint32_t cycles = PERF_CYCLES - c0, instret = PERF_INSTRET - n0;
    uint32_t ia = PERF_ICACHE_HITS - ia0, im = PERF_ICACHE_MISS - im0;
    uint32_t da = PERF_DCACHE_HITS - da0, dm = PERF_DCACHE_MISS - dm0;

    // The same sums computed the slow way, as a check.
    uint32_t expect_sum = 0, expect_check = 0;
    for (int pass = 0; pass < 3; pass++)
        for (uint32_t i = 0; i < N; i++)
            expect_sum += (i * 2654435761u) ^ pass;
    for (uint32_t i = 0; i < N; i++)
        expect_check += i * 2654435761u + (i % 4 == 0);

    printf("running from %p\n", (void *)main);
    printf("instructions %u cycles %u\n", instret, cycles);
    printf("icache accesses %u misses %u\n", ia, im);
    printf("dcache accesses %u misses %u\n", da, dm);
    printf(sum == expect_sum && check == expect_check ? "CACHE PASS\n" : "CACHE FAIL\n");
    printf("DONE\n");
    return 0;
}
