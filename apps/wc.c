/* wc.c - counts lines, words and bytes: run wc.app FILE [FILE...]
 * Shows command-line arguments, open/read and malloc. */
#include "lexos.h"

static void count(const char *name)
{
    int fd = open(name, O_READ), n, size, i, lines = 0, words = 0, in_word = 0;
    char *buf;
    if (fd < 0) { puts(name); puts(": can't open it\n"); return; }
    size = fsize(fd);
    buf = malloc(size + 1);
    if (!buf) { puts("out of memory\n"); close(fd); return; }
    n = read(fd, buf, size);
    close(fd);
    for (i = 0; i < n; i++) {
        char c = buf[i];
        if (c == '\n') lines++;
        if (c == ' ' || c == '\n' || c == '\r' || c == '\t') in_word = 0;
        else if (!in_word) { in_word = 1; words++; }
    }
    free(buf);
    print_int(lines); putchar(' ');
    print_int(words); putchar(' ');
    print_int(n);     putchar(' ');
    puts(name); putchar('\n');
}

int main(int argc, char **argv)
{
    int i;
    if (argc < 2) { puts("Usage: run wc.app FILE [FILE...]  (lines words bytes)\n"); return 1; }
    for (i = 1; i < argc; i++) count(argv[i]);
    return 0;
}
