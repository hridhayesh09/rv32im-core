#include "soc.h"

uint64_t timer_cycles(void)
{
    // The 64-bit counter is read in two halves. If the high half changes between the reads,
    // the low half wrapped around in between, so read again.
    uint32_t hi, lo;
    do {
        hi = TIMER_TIME_HI;
        lo = TIMER_TIME_LO;
    } while (hi != TIMER_TIME_HI);
    return ((uint64_t)hi << 32) | lo;
}

void delay_us(uint32_t us)
{
    uint64_t end = timer_cycles() + (uint64_t)us * (TIMER_CLK_HZ / 1000000u);
    while (timer_cycles() < end)
        ;
}

void delay_ms(uint32_t ms)
{
    while (ms--)
        delay_us(1000);
}
