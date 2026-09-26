/* HELLO.C - compile it inside LexOS:
 *   run cc.app hello.c
 *   run hello.app Lex
 */
int main(int argc, char **argv)
{
    int i;
    printf("Hello from a C program built inside LexOS!\n");
    for (i = 1; i < argc; i++)
        printf("argument %d: %s\n", i, argv[i]);
    return 0;
}
