/* PRIMES.C - the sieve of Eratosthenes, with pointers */
#define MAX 1000

char sieve[MAX];

int main()
{
    char *p;
    int i, j, count = 0;
    for (p = sieve; p < sieve + MAX; p++) *p = 1;
    sieve[0] = sieve[1] = 0;
    for (i = 2; i * i < MAX; i++)
        if (sieve[i])
            for (j = i * i; j < MAX; j += i) sieve[j] = 0;
    for (i = 0; i < MAX; i++)
        if (sieve[i]) {
            printf("%d ", i);
            count++;
        }
    printf("\n%d primes below %d\n", count, MAX);
    return 0;
}
