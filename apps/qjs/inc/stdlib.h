#ifndef LX_STDLIB_H
#define LX_STDLIB_H
#include <stddef.h>
void *malloc(size_t);
void free(void *);
void *calloc(size_t, size_t);
void *realloc(void *, size_t);
void abort(void) __attribute__((noreturn));
void exit(int) __attribute__((noreturn));
double strtod(const char *, char **);
long strtol(const char *, char **, int);
unsigned long strtoul(const char *, char **, int);
long long strtoll(const char *, char **, int);
unsigned long long strtoull(const char *, char **, int);
int atoi(const char *);
int abs(int);
long labs(long);
long long llabs(long long);
char *getenv(const char *);
#define alloca(n) __builtin_alloca(n)
void qsort(void *, size_t, size_t, int (*)(const void *, const void *));
#endif
