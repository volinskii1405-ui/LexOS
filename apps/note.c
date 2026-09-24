/* note.c - a to-do list in a file:
 *   run note.app todo.txt buy milk   adds a line to todo.txt
 *   run note.app todo.txt            lists it, numbered
 * Shows command-line arguments and files opened for append/read. */
#include "lexos.h"

int main(int argc, char **argv)
{
    int fd, i;
    if (argc < 2) { puts("Usage: run note.app FILE [text to add]\n"); return 1; }

    if (argc > 2) {
        fd = open(argv[1], O_APPEND);
        if (fd < 0) { puts("Can't open "); puts(argv[1]); putchar('\n'); return 1; }
        for (i = 2; i < argc; i++) {
            if (i > 2) fwrite(fd, " ", 1);
            fputs(fd, argv[i]);
        }
        fwrite(fd, "\n", 1);
        close(fd);
        puts("Added.\n");
        return 0;
    }

    fd = open(argv[1], O_READ);
    if (fd < 0) { puts(argv[1]); puts(": no such file yet\n"); return 1; }
    {
        char c;
        int line = 1, start = 1;
        while (read(fd, &c, 1) == 1) {
            if (start) { setcolor(0x0E); print_int(line++); puts(". "); setcolor(0x07); start = 0; }
            putchar(c);
            if (c == '\n') start = 1;
        }
    }
    close(fd);
    return 0;
}
