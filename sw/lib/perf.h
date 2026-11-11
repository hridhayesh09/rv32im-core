// Performance counters: the standard RISC-V counter CSRs (rtl/csr.sv).
#ifndef PERF_H
#define PERF_H

#include <stdint.h>

// Read a CSR by number (the number must be a compile-time constant). The "memory" clobber keeps
// the compiler from moving loads and stores across the read, so a measurement covers exactly
// the code between two reads.
#define CSR_READ(num) ({ uint32_t _v; __asm__ volatile("csrr %0, %1" : "=r"(_v) : "i"(num) : "memory"); _v; })

#define PERF_CYCLES       CSR_READ(0xB00)   // clock cycles (low 32 bits)
#define PERF_INSTRET      CSR_READ(0xB02)   // instructions retired

// mhpmcounter3..11: what each one counts is fixed in hardware. A CSR read happens in EX, so events
// caused by the two instructions just before it (still in MEM and WB) may not be counted yet: to
// include a memory access's wait cycles, read at least 2 instructions after it (see perf_test.c).
// minstret has no such gap: the core adds the instructions still in flight.
#define PERF_BRANCHES     CSR_READ(0xB03)   // branches and jumps executed
#define PERF_MISPREDICTS  CSR_READ(0xB04)   // of those, the ones that changed the fetch path
#define PERF_LOAD_USE     CSR_READ(0xB05)   // load-use stall cycles
#define PERF_MULDIV_WAIT  CSR_READ(0xB06)   // cycles waiting for multiply/divide
#define PERF_MEM_WAIT     CSR_READ(0xB07)   // cycles waiting for slow memory (bus, SDRAM)
#define PERF_ICACHE_HITS  CSR_READ(0xB08)   // instruction cache accesses
#define PERF_ICACHE_MISS  CSR_READ(0xB09)   // instruction cache misses
#define PERF_DCACHE_HITS  CSR_READ(0xB0A)   // data cache accesses
#define PERF_DCACHE_MISS  CSR_READ(0xB0B)   // data cache misses

#endif
