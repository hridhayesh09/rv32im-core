// Count the primes below 2000 by trial division: exercises the divider (the % operator
// compiles to REMU). main returns 0 if the count is right.

static int is_prime(unsigned n)
{
    if (n < 2)
        return 0;
    for (unsigned d = 2; d * d <= n; d++) {
        if (n % d == 0)
            return 0;
    }
    return 1;
}

int main(void)
{
    unsigned count = 0;
    for (unsigned n = 0; n < 2000; n++)
        count += is_prime(n);
    return count == 303 ? 0 : 1;   // there are 303 primes below 2000
}
