// MNIST digit classification (784 -> 64 -> 10, int8) on the SoC, two ways:
//   software: the whole network in C on the CPU
//   NPU:      the matrix products on the 16x16 systolic array, the rest on the CPU
// The model, test images and NumPy's answers are in SDRAM (tools/export_mnist.py). Every
// image's 10 logits from both paths must equal NumPy's exactly.
#include "npu.h"
#include "soc.h"

#ifndef N_SOFTWARE
#define N_SOFTWARE 10          // images run in software (slow)
#endif
#ifndef N_NPU
#define N_NPU 200              // images run on the NPU
#endif
#define BATCH 20               // images per NPU batch: 20 x 49 activation rows fit in 1024

#define REQUANT_MULT  9710     // edge-ml-accelerator's requantize: (acc * M + 2^(S-1)) >> S
#define REQUANT_SHIFT 24

#define SDRAM 0x40000000u
typedef struct {
    uint32_t magic, n_images;
    uint32_t w1, w2, b1, b2, qlut, images, labels, logits;
} blob_header_t;

static const volatile blob_header_t *const blob = (const volatile blob_header_t *)SDRAM;
#define AT(off) (SDRAM + (off))

static int8_t qlut[256];
static int32_t b1[64], b2[16];

// Weight tile (kt, nt) of a layer with n_tiles output tiles: 64 words in SDRAM.
static const volatile uint32_t *tile(uint32_t base, int kt, int nt, int n_tiles)
{
    return (const volatile uint32_t *)AT(base + (uint32_t)(kt * n_tiles + nt) * 256);
}

static int8_t requantize(int32_t acc)
{
    int64_t v = ((int64_t)acc * REQUANT_MULT + (1 << (REQUANT_SHIFT - 1))) >> REQUANT_SHIFT;
    return v < 0 ? 0 : v > 127 ? 127 : (int8_t)v;   // ReLU folded into the clip
}

static int argmax10(const int32_t *v)
{
    int best = 0;
    for (int i = 1; i < 10; i++)
        if (v[i] > v[best])
            best = i;
    return best;
}

// ---------------------------------------------------------------- software

static void infer_software(int image, int32_t logits[10])
{
    static int8_t x[784];
    int32_t acc1[64];
    int8_t h[64];
    const volatile uint32_t *pixels = (const volatile uint32_t *)AT(blob->images + 784u * image);
    for (int i = 0; i < 196; i++) {
        uint32_t w = pixels[i];
        for (int b = 0; b < 4; b++)
            x[4 * i + b] = qlut[(w >> (8 * b)) & 0xFF];
    }

    // Layer 1: acc1 = x . W1 + b1. Row k of W1 is in 4 tiles (one per 16 outputs), 4 words each.
    for (int n = 0; n < 64; n++)
        acc1[n] = b1[n];
    for (int k = 0; k < 784; k++) {
        int32_t xk = x[k];
        for (int nt = 0; nt < 4; nt++) {
            const volatile uint32_t *row = tile(blob->w1, k / 16, nt, 4) + 4 * (k % 16);
            for (int wi = 0; wi < 4; wi++) {
                uint32_t w = row[wi];
                int32_t *acc = &acc1[16 * nt + 4 * wi];
                acc[0] += xk * (int8_t)(w);
                acc[1] += xk * (int8_t)(w >> 8);
                acc[2] += xk * (int8_t)(w >> 16);
                acc[3] += xk * (int8_t)(w >> 24);
            }
        }
    }
    for (int n = 0; n < 64; n++)
        h[n] = requantize(acc1[n]);

    // Layer 2: logits = h . W2 + b2.
    for (int n = 0; n < 10; n++) {
        int32_t acc = b2[n];
        for (int k = 0; k < 64; k++) {
            const volatile uint8_t *w = (const volatile uint8_t *)tile(blob->w2, k / 16, 0, 1);
            acc += h[k] * (int8_t)w[16 * (k % 16) + n];
        }
        logits[n] = acc;
    }
}

// ---------------------------------------------------------------- NPU

// Classify images first .. first+count-1 (count <= BATCH).
static void infer_npu(int first, int count, int32_t logits[][10])
{
    // Activations: image m's 784 inputs as 49 rows of 16, rows m*49 .. m*49+48.
    for (int m = 0; m < count; m++) {
        const volatile uint32_t *pixels =
            (const volatile uint32_t *)AT(blob->images + 784u * (first + m));
        for (int kt = 0; kt < 49; kt++) {
            volatile uint32_t *row = NPU_A(m * 49 + kt);
            for (int wi = 0; wi < 4; wi++) {
                uint32_t p = pixels[4 * kt + wi];
                row[wi] = (uint8_t)qlut[p & 0xFF] | (uint8_t)qlut[(p >> 8) & 0xFF] << 8 |
                          (uint8_t)qlut[(p >> 16) & 0xFF] << 16 |
                          (uint32_t)(uint8_t)qlut[p >> 24] << 24;
            }
        }
    }

    // Layer 1: for each 16-output tile nt, sum the 49 input tiles into C rows m*4 + nt.
    for (int nt = 0; nt < 4; nt++) {
        for (int kt = 0; kt < 49; kt++) {
            npu_load_weights(tile(blob->w1, kt, nt, 4));
            npu_matmul(count, kt, 49, nt, 4, kt > 0);
        }
    }

    // Requantize (bias, scale, ReLU) on the CPU; the 64 hidden values of image m become
    // activation rows m*4 .. m*4+3 for layer 2.
    for (int m = 0; m < count; m++) {
        for (int nt = 0; nt < 4; nt++) {
            const volatile int32_t *c = NPU_C(m * 4 + nt);
            uint32_t packed[4] = {0, 0, 0, 0};
            for (int j = 0; j < 16; j++)
                packed[j / 4] |= (uint32_t)(uint8_t)requantize(c[j] + b1[16 * nt + j]) << (8 * (j % 4));
            volatile uint32_t *row = NPU_A(m * 4 + nt);
            for (int wi = 0; wi < 4; wi++)
                row[wi] = packed[wi];
        }
    }

    // Layer 2: 4 input tiles, one output tile; results in C rows 128 + m.
    for (int kt = 0; kt < 4; kt++) {
        npu_load_weights(tile(blob->w2, kt, 0, 1));
        npu_matmul(count, kt, 4, 128, 1, kt > 0);
    }
    for (int m = 0; m < count; m++) {
        const volatile int32_t *c = NPU_C(128 + m);
        for (int n = 0; n < 10; n++)
            logits[m][n] = c[n] + b2[n];
    }
}

// ---------------------------------------------------------------- main

static int check(const char *what, int image, const int32_t logits[10], int *correct)
{
    const volatile int32_t *expected = (const volatile int32_t *)AT(blob->logits + 40u * image);
    const volatile uint8_t *labels = (const volatile uint8_t *)AT(blob->labels);
    int mismatches = 0;
    for (int n = 0; n < 10; n++)
        mismatches += logits[n] != expected[n];
    if (mismatches)
        printf("%s image %d: %d logits differ from NumPy\n", what, image, mismatches);
    *correct += argmax10(logits) == labels[image];
    return mismatches != 0;
}

int main(void)
{
    printf("MNIST on rv32im-core\n");
    if (blob->magic != 0x54534E4Du) {
        printf("no model in SDRAM: load build/mnist/mnist_blob.bin at 0x40000000\n");
        printf("DONE\n");
        return 1;
    }
    int n_images = blob->n_images;
    int n_sw = N_SOFTWARE < n_images ? N_SOFTWARE : n_images;
    int n_npu = N_NPU < n_images ? N_NPU : n_images;
    const volatile int8_t *lut = (const volatile int8_t *)AT(blob->qlut);
    for (int i = 0; i < 256; i++)
        qlut[i] = lut[i];
    for (int i = 0; i < 64; i++)
        b1[i] = ((const volatile int32_t *)AT(blob->b1))[i];
    for (int i = 0; i < 16; i++)
        b2[i] = ((const volatile int32_t *)AT(blob->b2))[i];

    int errors = 0, sw_correct = 0, npu_correct = 0;
    int32_t logits[BATCH][10];

    uint64_t t0 = timer_cycles();
    for (int i = 0; i < n_sw; i++) {
        infer_software(i, logits[0]);
        errors += check("software", i, logits[0], &sw_correct);
    }
    uint64_t t1 = timer_cycles();
    for (int first = 0; first < n_npu; first += BATCH) {
        int count = n_npu - first < BATCH ? n_npu - first : BATCH;
        infer_npu(first, count, logits);
        for (int m = 0; m < count; m++)
            errors += check("NPU", first + m, logits[m], &npu_correct);
    }
    uint64_t t2 = timer_cycles();

    // 32-bit division (no 64-bit divide in this runtime): runs stay far below 2^32 cycles.
    uint32_t sw_per_image = (uint32_t)(t1 - t0) / n_sw;
    uint32_t npu_per_image = (uint32_t)(t2 - t1) / n_npu;
    uint32_t mhz = TIMER_CLK_HZ / 1000000u;
    printf("software: %d images, %d/%d correct, %u cycles per image (%u us)\n",
           n_sw, sw_correct, n_sw, sw_per_image, sw_per_image / mhz);
    printf("NPU:      %d images, %d/%d correct, %u cycles per image (%u us)\n",
           n_npu, npu_correct, n_npu, npu_per_image, npu_per_image / mhz);
    printf("speedup: %u.%02ux\n", sw_per_image / npu_per_image,
           (sw_per_image % npu_per_image) * 100 / npu_per_image);
    printf(errors ? "MNIST FAIL: %d images differ from NumPy\n" : "MNIST PASS: all logits bit-exact\n",
           errors);
    printf("DONE\n");
    return errors != 0;
}
