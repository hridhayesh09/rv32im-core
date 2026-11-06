// Fibonacci two ways: recursive (lots of calls, stack use and returns) and iterative.
// main returns 0 if everything matches the known values.

static unsigned fib_recursive(unsigned n)
{
    return n < 2 ? n : fib_recursive(n - 1) + fib_recursive(n - 2);
}

static unsigned fib_iterative(unsigned n)
{
    unsigned a = 0, b = 1;
    while (n--) {
        unsigned t = a + b;
        a = b;
        b = t;
    }
    return a;
}

int main(void)
{
    for (unsigned n = 0; n <= 18; n++) {
        if (fib_recursive(n) != fib_iterative(n))
            return n + 1;
    }
    if (fib_iterative(24) != 46368)
        return 100;
    if (fib_iterative(47) != 2971215073u)   // the largest that fits in 32 bits
        return 101;
    return 0;
}
