// Sort 256 pseudo-random numbers with quicksort, then check the result is in order and is
// a permutation of the input (same sum and xor). main returns 0 on success.

#define N 256

static unsigned data[N];
static unsigned seed = 12345;

static unsigned next_random(void)
{
    seed = seed * 1103515245u + 12345u;   // linear congruential generator
    return seed >> 8;
}

static void quicksort(unsigned *a, int lo, int hi)
{
    while (lo < hi) {
        unsigned pivot = a[(lo + hi) / 2];
        int i = lo, j = hi;
        while (i <= j) {
            while (a[i] < pivot) i++;
            while (a[j] > pivot) j--;
            if (i <= j) {
                unsigned t = a[i];
                a[i] = a[j];
                a[j] = t;
                i++;
                j--;
            }
        }
        // Recurse into the smaller half, loop on the larger: keeps the stack shallow.
        if (j - lo < hi - i) {
            quicksort(a, lo, j);
            lo = i;
        } else {
            quicksort(a, i, hi);
            hi = j;
        }
    }
}

int main(void)
{
    unsigned sum = 0, xor = 0;
    for (int i = 0; i < N; i++) {
        data[i] = next_random();
        sum += data[i];
        xor ^= data[i];
    }

    quicksort(data, 0, N - 1);

    for (int i = 1; i < N; i++) {
        if (data[i - 1] > data[i])
            return 1;
    }
    for (int i = 0; i < N; i++) {
        sum -= data[i];
        xor ^= data[i];
    }
    if (sum != 0 || xor != 0)
        return 2;
    return 0;
}
