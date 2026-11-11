// CoreMark port for the rv32im-core SoC: timing with the cycle counter, seeds, and a final
// report of the raw numbers (cycles and iterations) so CoreMark/MHz can be computed exactly
// without floating point.
#include "coremark.h"
#include "core_portme.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

static inline ee_u32 read_cycles(void)
{
    ee_u32 c;
    __asm__ volatile("rdcycle %0" : "=r"(c) :: "memory");
    return c;
}

static inline ee_u32 read_csr_mhpm(int n)
{
    ee_u32 v = 0;
    switch (n) {   // the CSR number must be a constant
    case 3: __asm__ volatile("csrr %0, 0xB03" : "=r"(v) :: "memory"); break;   // branches
    case 4: __asm__ volatile("csrr %0, 0xB04" : "=r"(v) :: "memory"); break;   // mispredicts
    }
    return v;
}

static CORETIMETYPE start_time_val, stop_time_val;
static ee_u32 start_instret, stop_instret, start_branches, stop_branches, start_misp, stop_misp;

void start_time(void)
{
    start_branches = read_csr_mhpm(3);
    start_misp     = read_csr_mhpm(4);
    __asm__ volatile("rdinstret %0" : "=r"(start_instret) :: "memory");
    start_time_val = read_cycles();
}

void stop_time(void)
{
    stop_time_val = read_cycles();
    __asm__ volatile("rdinstret %0" : "=r"(stop_instret) :: "memory");
    stop_branches = read_csr_mhpm(3);
    stop_misp     = read_csr_mhpm(4);
}

CORE_TICKS get_time(void)
{
    return (CORE_TICKS)(stop_time_val - start_time_val);
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)ticks / (secs_ret)CLOCK_HZ;
}

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    p->portable_id = 1;
}

// The timed run, as raw counter values (the last timed run, i.e. the one CoreMark reports).
void portable_fini(core_portable *p)
{
    p->portable_id = 0;
    ee_printf("Timed cycles     : %u\n", stop_time_val - start_time_val);
    ee_printf("Timed instret    : %u\n", stop_instret - start_instret);
    ee_printf("Timed branches   : %u\n", stop_branches - start_branches);
    ee_printf("Timed mispredicts: %u\n", stop_misp - start_misp);
    ee_printf("COREMARK DONE\n");
}
