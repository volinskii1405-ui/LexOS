/* (LexOS's QuickJS: the little of stdio it uses - libc.c) */
#ifndef LX_STDIO_H
#define LX_STDIO_H
#include <stddef.h>
#include <stdarg.h>
typedef struct lx_file FILE;
extern FILE *stdout, *stderr, *stdin;
#define EOF (-1)
int printf(const char *, ...);
int fprintf(FILE *, const char *, ...);
int vfprintf(FILE *, const char *, va_list);
int snprintf(char *, size_t, const char *, ...);
int vsnprintf(char *, size_t, const char *, va_list);
int sprintf(char *, const char *, ...);
int fputs(const char *, FILE *);
int fputc(int, FILE *);
int putc(int, FILE *);
int putchar(int);
int puts(const char *);
size_t fwrite(const void *, size_t, size_t, FILE *);
int fflush(FILE *);
#endif
