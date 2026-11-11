// CoreMark port for the rv32im-core SoC (see third_party/coremark/barebones for the template).
// Time is measured with the cycle counter (rdcycle), so one tick is one clock cycle; output
// goes through the UART printf in sw/lib.
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>
#include <stdint.h>

int printf(const char *fmt, ...);

#define HAS_FLOAT  0          // no FPU and no float printf: seconds are printed as integers
#define HAS_TIME_H 0
#define USE_CLOCK  0
#define HAS_STDIO  0
#define HAS_PRINTF 1          // ee_printf = printf (sw/lib/printf.c)

#ifndef CLOCK_HZ
#define CLOCK_HZ 50000000     // the DE10-Lite's 50 MHz clock
#endif

#define COMPILER_VERSION "GCC" __VERSION__
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS "-O2 -march=rv32im_zicsr_zifencei -mabi=ilp32"
#endif
#ifndef MEM_LOCATION
#define MEM_LOCATION "STATIC"
#endif

typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
typedef ee_u32         ee_ptr_int;
typedef size_t         ee_size_t;

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS;

#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD  MEM_STATIC

#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0

#define MAIN_HAS_NOARGC   1
#define MAIN_HAS_NORETURN 0

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

extern ee_u32 default_num_contexts;

#endif
