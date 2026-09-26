/* GUESS.C - guess the number (keyboard input, rand) */
int main()
{
    char line[20];
    int secret, guess, tries = 0;
    srand(millis());
    secret = rand() % 100 + 1;
    printf("I'm thinking of a number from 1 to 100.\n");
    for (;;) {
        printf("Your guess: ");
        readline(line, 20);
        guess = atoi(line);
        tries++;
        if (guess < secret) printf("Higher!\n");
        else if (guess > secret) printf("Lower!\n");
        else break;
    }
    printf("Yes, %d - in %d tries.\n", secret, tries);
    return 0;
}
