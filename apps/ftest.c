/* ftest.c - floating point in a LexOS program.
 * Prints a few results of the math functions in lexos.h, then sums
 * 1/k^2 (-> pi^2/6) for a while, printing its progress: switch to
 * another console with Alt+T / Alt+2 and run ftest.app there too - each
 * program keeps its own FPU registers, so both sums come out right.
 * Any key stops the sum early. */
#include "lexos.h"

static void show(const char *what, double v)
{
    puts(what);
    print_float(v, 9);
    putchar('\n');
}

int main(int argc, char **argv)
{
    double sum = 0, k;
    int steps = argc > 1 ? atoi(argv[1]) : 40, i;

    setcolor(0x0B);
    puts("Floating point in ring 3:\n");
    setcolor(0x07);
    show("  sqrt(2)          = ", sqrt(2));
    show("  sin(pi/6)        = ", sin(M_PI / 6));
    show("  cos(pi/3)        = ", cos(M_PI / 3));
    show("  atan2(1, 1) * 4  = ", atan2(1, 1) * 4);
    show("  exp(1)           = ", exp(1));
    show("  log(10)          = ", log(10));
    show("  pow(2, 0.5)      = ", pow(2, 0.5));
    show("  1 / 3.0          = ", 1 / 3.0);

    puts("\nSumming 1/k^2 (pi^2/6 = ");
    print_float(M_PI * M_PI / 6, 9);
    puts("):\n");
    k = 1;
    for (i = 1; i <= steps; i++) {
        int j;
        for (j = 0; j < 25000; j++, k += 1) sum += 1 / (k * k);
        puts("  after ");
        print_int(i * 25000);
        puts(" terms: ");
        print_float(sum, 9);
        putchar('\n');
        if (pollkey()) break;                           /* (Alt+digit switches here) */
        sleep_ms(100);
    }
    puts("Off from pi^2/6 by ");
    print_float(M_PI * M_PI / 6 - sum, 9);
    puts(" - about 1/terms, as it should be.\n");
    return 0;
}
