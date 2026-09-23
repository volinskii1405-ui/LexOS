/* guess.c - a LexOS program in C: guess the number, in ring 3.
 * Build: make apps. Run: hostget guess.app, then run guess.app. */
#include "lexos.h"

static unsigned seed;

static int random_upto(int n)
{
    seed = seed * 1103515245u + 12345u;
    return (int)((seed >> 16) % (unsigned)n) + 1;
}

int main(void)
{
    char line[16];
    int games = 0, best = 0;

    setcolor(0x0B);
    puts("=== Guess the number - a C program running in ring 3 ===\n");
    setcolor(0x07);
    seed = ticks();

    for (;;) {
        int secret = random_upto(100), tries = 0, guess;
        puts("I'm thinking of a number from 1 to 100.\n");
        do {
            puts("Your guess: ");
            readline(line, sizeof line);
            guess = atoi(line);
            tries++;
            if (guess < secret)      { puts("Higher!\n"); beep(400, 60); }
            else if (guess > secret) { puts("Lower!\n");  beep(300, 60); }
        } while (guess != secret);

        games++;
        if (!best || tries < best) best = tries;
        setcolor(0x0A);
        puts("Right! ");
        print_int(tries);
        puts(" tries (best so far: ");
        print_int(best);
        puts(").\n");
        setcolor(0x07);
        beep(880, 120);

        puts("Again? (y/n) ");
        if (getkey() != 'y') break;
        putchar('\n');
    }
    puts("\nBye!\n");
    return 0;
}
