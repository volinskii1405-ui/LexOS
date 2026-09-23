/* lexos.h - for LexOS programs written in C (`run <name>.app`).
 *
 * A program is a flat 32-bit binary, loaded at 0x800000, running in
 * ring 3 with 1MB of memory of its own. crt0.asm calls main() and
 * passes its return value to exit(). There's no C library - just
 * these, all thin wrappers around the system calls (int 0x80, see
 * src/usermode.asm), plus a few string helpers.
 *
 * Build: see the Makefile's `apps` target (gcc -m32 -ffreestanding,
 * linked with app.ld). */
#ifndef LEXOS_H
#define LEXOS_H

static inline int lx_syscall(int n, int a, int b)
{
    int r;
    __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "b"(a), "c"(b) : "memory");
    return r;
}

static inline void exit(int code)             { lx_syscall(0, code, 0); for (;;); }
static inline int  write(const char *s, int n) { return lx_syscall(1, (int)s, n); }
static inline int  getkey(void)               { return lx_syscall(2, 0, 0) & 0xFF; }
static inline int  getkey_full(void)          { return lx_syscall(2, 0, 0); }
static inline int  pollkey(void)              { return lx_syscall(3, 0, 0); }
static inline unsigned ticks(void)            { return (unsigned)lx_syscall(4, 0, 0); }
static inline void sleep_ms(int ms)           { lx_syscall(5, ms, 0); }
static inline void clear(void)                { lx_syscall(6, 0, 0); }
static inline void setcursor(int row, int col){ lx_syscall(7, row, col); }
static inline void setcolor(int attr)         { lx_syscall(8, attr, 0); }
static inline int  readline(char *buf, int n) { return lx_syscall(9, (int)buf, n); }
static inline void beep(int hz, int ms)       { lx_syscall(10, hz, ms); }

static inline int strlen(const char *s)       { int n = 0; while (s[n]) n++; return n; }
static inline void puts(const char *s)        { write(s, strlen(s)); }
static inline void putchar(char c)            { write(&c, 1); }

static inline void print_int(int v)
{
    char buf[12];
    int i = 11;
    unsigned u = v < 0 ? -(unsigned)v : (unsigned)v;
    buf[i] = 0;
    do { buf[--i] = '0' + u % 10; u /= 10; } while (u);
    if (v < 0) buf[--i] = '-';
    puts(buf + i);
}

static inline int atoi(const char *s)
{
    int v = 0, neg = 0;
    while (*s == ' ') s++;
    if (*s == '-') { neg = 1; s++; }
    while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
    return neg ? -v : v;
}

#endif
