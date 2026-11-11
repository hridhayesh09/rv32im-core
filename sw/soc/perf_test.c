// Performance counters: small assembly kernels whose events are known exactly, measured with
// the counters before and after.
#include "perf.h"
#include "soc.h"

static uint32_t data[4];

int main(void)
{
    uint32_t b0, m0, b1, m1, l0, l1, w0, w1, i0, i1;

    // 100 loop iterations: 100 branches, taken 99 times. Mispredicts depend on the predictor
    // (tests/soc/test_soc.py explains the count).
    b0 = PERF_BRANCHES; m0 = PERF_MISPREDICTS; i0 = PERF_INSTRET;
    __asm__ volatile("li t0, 100\n1: addi t0, t0, -1\nbnez t0, 1b" ::: "t0");
    b1 = PERF_BRANCHES; m1 = PERF_MISPREDICTS; i1 = PERF_INSTRET;
    printf("loop: branches %u mispredicts %u instret %u\n", b1 - b0, m1 - m0, i1 - i0);

    // 50 loads, each used by the very next instruction: 50 load-use stalls.
    l0 = PERF_LOAD_USE;
    __asm__ volatile(".rept 50\nlw t1, 0(%0)\naddi t1, t1, 1\n.endr" :: "r"(data) : "t1");
    l1 = PERF_LOAD_USE;
    printf("load-use: %u\n", l1 - l0);

    // 10 divides, then 10 multiplies.
    w0 = PERF_MULDIV_WAIT;
    __asm__ volatile(".rept 10\ndivu t2, %0, %1\n.endr" :: "r"(1000), "r"(7) : "t2");
    w1 = PERF_MULDIV_WAIT;
    printf("divide wait: %u\n", w1 - w0);
    w0 = PERF_MULDIV_WAIT;
    __asm__ volatile(".rept 10\nmul t2, %0, %1\n.endr" :: "r"(1000), "r"(7) : "t2");
    w1 = PERF_MULDIV_WAIT;
    printf("multiply wait: %u\n", w1 - w0);

    // A bus access (the timer) waits for the bus: memory wait cycles go up. The two NOPs let the
    // load finish waiting (in MEM) before the counter is read.
    w0 = PERF_MEM_WAIT;
    (void)TIMER_TIME_LO;
    __asm__ volatile("nop\nnop");
    w1 = PERF_MEM_WAIT;
    printf("bus read wait: %u\n", w1 - w0);
    printf("DONE\n");
    return 0;
}
