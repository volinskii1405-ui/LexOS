/* FIB.C - recursion, loops, arrays, switch */
#define N 20

int memo[N + 1];

int fib(int n)
{
    if (n < 2) return n;
    if (memo[n]) return memo[n];
    return memo[n] = fib(n - 1) + fib(n - 2);
}

char *kind(int n)
{
    switch (n % 3) {
    case 0: return "divisible by 3";
    case 1: return "remainder 1";
    default: return "remainder 2";
    }
}

int main()
{
    int i;
    for (i = 0; i <= N; i++)
        printf("fib(%d) = %d  (%s)\n", i, fib(i), kind(fib(i)));
    return 0;
}
