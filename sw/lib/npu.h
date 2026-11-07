// The NPU (rtl/npu/wb_npu.sv): a 16x16 int8 systolic array with local buffers.
#ifndef NPU_H
#define NPU_H

#include <stdint.h>

#define NPU_REG(off)  (*(volatile uint32_t *)(0x10004000u + (off)))
#define NPU_CTRL      NPU_REG(0x00)   // bit 0 start, bit 1 accumulate
#define NPU_STATUS    NPU_REG(0x04)   // bit 0 busy
#define NPU_A_BASE    NPU_REG(0x08)
#define NPU_A_STRIDE  NPU_REG(0x0C)
#define NPU_C_BASE    NPU_REG(0x10)
#define NPU_C_STRIDE  NPU_REG(0x14)
#define NPU_COUNT     NPU_REG(0x18)
#define NPU_W_DATA    NPU_REG(0x20)
#define NPU_W_RESET   NPU_REG(0x24)
#define NPU_CYCLES    NPU_REG(0x28)

#define NPU_A_ROWS 1024   // activation buffer: rows of 16 int8
#define NPU_C_ROWS 256    // result buffer: rows of 16 int32

// Activation row r: 4 words (16 int8, little-endian). Write only.
#define NPU_A(r) ((volatile uint32_t *)(0x30000000u + 16u * (r)))
// Result row r: 16 int32. Read only while the NPU is idle.
#define NPU_C(r) ((volatile int32_t *)(0x30010000u + 64u * (r)))

// Load a 16x16 weight tile: 64 words, row k (input) = 4 words of W[k][0..15].
static inline void npu_load_weights(const volatile uint32_t *tile)
{
    NPU_W_RESET = 0;
    for (int i = 0; i < 64; i++)
        NPU_W_DATA = tile[i];
}

// C[c_base + i*c_stride] (+)= A[a_base + i*a_stride] x W for i < count. Waits until done.
static inline void npu_matmul(int count, int a_base, int a_stride, int c_base, int c_stride,
                              int accumulate)
{
    NPU_A_BASE = a_base;
    NPU_A_STRIDE = a_stride;
    NPU_C_BASE = c_base;
    NPU_C_STRIDE = c_stride;
    NPU_COUNT = count;
    NPU_CTRL = 1 | (accumulate ? 2 : 0);
    while (NPU_STATUS & 1)
        ;
}

#endif
