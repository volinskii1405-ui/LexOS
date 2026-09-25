/* lexos.h - for LexOS programs written in C (`run <name>.app [args]`).
 *
 * A program is a flat 32-bit binary, loaded at 0x800000, running in
 * ring 3 with 4MB of memory of its own. crt0.asm splits the command
 * line into argc/argv, calls main(argc, argv) and passes its return
 * value to exit(). There's no C library - just these: thin wrappers
 * around the system calls (int 0x80, see src/usermode.asm and
 * src/appsys.asm), string/memory helpers, and malloc/free working in
 * the memory between the program's end and its stack.
 *
 * Build: see the Makefile's `apps` target (gcc -m32 -ffreestanding,
 * linked with app.ld). */
#ifndef LEXOS_H
#define LEXOS_H

typedef unsigned int size_t;
#define NULL ((void *)0)

static inline int lx_syscall3(int n, int a, int b, int c)
{
    int r;
    __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "b"(a), "c"(b), "d"(c) : "memory");
    return r;
}
static inline int lx_syscall(int n, int a, int b) { return lx_syscall3(n, a, b, 0); }

/* --- the screen and keyboard --- */
static inline void exit(int code)             { lx_syscall(0, code, 0); for (;;); }
static inline int  write(const char *s, int n) { return lx_syscall(1, (int)s, n); }
static inline int  getkey(void)               { return lx_syscall(2, 0, 0) & 0xFF; }
static inline int  getkey_full(void)          { return lx_syscall(2, 0, 0); }  /* ASCII | scancode << 8 */
static inline int  pollkey(void)              { return lx_syscall(3, 0, 0); }  /* the same, or 0 */
static inline unsigned ticks(void)            { return (unsigned)lx_syscall(4, 0, 0); } /* 18.2/s */
static inline void sleep_ms(int ms)           { lx_syscall(5, ms, 0); }
static inline unsigned millis(void)           { return (unsigned)lx_syscall(26, 0, 0); } /* since boot */
/* sleep_until(t): wait until millis() reaches t - for a steady frame
 * rate: unsigned next = millis(); for (;;) { ...draw...; next += 16;
 * sleep_until(next); }  gives 60 frames a second, however long the
 * drawing took (as long as it took less than 16ms). */
static inline void sleep_until(unsigned t)    { lx_syscall(27, (int)t, 0); }
static inline void clear(void)                { lx_syscall(6, 0, 0); }
static inline void setcursor(int row, int col){ lx_syscall(7, row, col); }
static inline void setcolor(int attr)         { lx_syscall(8, attr, 0); }
static inline int  readline(char *buf, int n) { return lx_syscall(9, (int)buf, n); }
static inline void beep(int hz, int ms)       { lx_syscall(10, hz, ms); }

/* --- files (in the shell's current folder; up to 4MB each, 8 open at once) ---
 * open() returns a handle, or -1. O_WRITE creates the file or empties
 * it; O_APPEND creates it if needed and starts at its end; O_UPDATE
 * reads and writes an existing one. What's written is saved when the
 * file is closed - or when the program ends, however it ends. */
#define O_READ   0
#define O_WRITE  1
#define O_APPEND 2
#define O_UPDATE 3
/* A name can have a path before it: "/DEMOS/SITE/INDEX.HTM", "SITE/A.HTM". */
static inline int open(const char *name, int mode)       { return lx_syscall(11, (int)name, mode); }
static inline int read(int fd, void *buf, int n)          { return lx_syscall3(12, fd, (int)buf, n); }
static inline int fwrite(int fd, const void *buf, int n)  { return lx_syscall3(13, fd, (int)buf, n); }
static inline int close(int fd)                           { return lx_syscall(14, fd, 0); }
static inline int seek(int fd, int pos)                   { return lx_syscall(15, fd, pos); } /* -1 = the end */
static inline int fsize(int fd)                           { return lx_syscall(16, fd, 0); }

/* --- graphics: 320x200, a byte per pixel ---
 * gfx_mode(1) switches the screen to graphics, gfx_mode(0) back to text
 * (it also goes back by itself when the program ends). Draw into a
 * 64000-byte buffer of your own and gfx_blit() it to the screen.
 * Colors: 0-15 the text colors, 16-31 grays, 32-247 a 6x6x6 cube -
 * RGB6(r, g, b) with each 0-5 - or set any color with gfx_palette(). */
#define GFX_W 320
#define GFX_H 200
#define RGB6(r, g, b) (32 + (r) * 36 + (g) * 6 + (b))
static inline void gfx_mode(int on)                       { lx_syscall(17, on, 0); }
static inline void gfx_blit(const void *frame)            { lx_syscall(18, (int)frame, 0); }
static inline void gfx_palette(int color, unsigned rgb)   { lx_syscall(19, color, (int)rgb); } /* 0xRRGGBB */

/* Higher resolutions: gfx_mode_ex(800, 600, 32) - width x height in
 * 8 bits per pixel (the palette above) or 32 (a pixel is 0x00RRGGBB,
 * see RGB()). Up to 1600x1200; returns 0, or -1 if the video can't.
 * gfx_blit() then takes a width*height*(bpp/8)-byte frame, and
 * gfx_blit_rect() copies just one rectangle of such a frame - quicker
 * when only part of the picture changed. */
#define RGB(r, g, b) ((unsigned)(r) << 16 | (unsigned)(g) << 8 | (unsigned)(b))
static inline int  gfx_mode_ex(int w, int h, int bpp)     { return lx_syscall3(21, w, h, bpp); }
static inline void gfx_blit_rect(const void *frame, int x, int y, int w, int h)
{ lx_syscall3(22, (int)frame, x | y << 16, w | h << 16); }

/* --- sound: a stream of 16-bit signed samples through the Sound Blaster ---
 * audio_open(22050, 2) - rate and channels (1 mono, 2 stereo, samples
 * interleaved left, right); 0, or -1 if there's no card or no free
 * voice. It's a voice of LexOS's mixer: it plays together with other
 * programs' sound and `play x.wav &` music; audio_volume(0-100). audio_write() waits until the card has room, so it
 * also paces a program that just keeps writing. audio_close() lets what
 * was written finish playing (the stream also stops when the program
 * ends). */
static inline int audio_open(int rate, int channels)     { return lx_syscall(23, rate, channels); }
static inline int audio_write(const short *s, int bytes) { return lx_syscall(24, (int)s, bytes); }
static inline int audio_close(void)                       { return lx_syscall(25, 0, 0); }
static inline int audio_volume(int percent)               { return lx_syscall(28, percent, 0); }

/* --- the mouse ---
 * mouse(m): m[0], m[1] = where the pointer is in the program's picture
 * (on the desktop: in its window; -1 if it can't tell), m[2] = the
 * buttons held (1 left, 2 right, 4 middle - only while it's over the
 * picture), m[3] = the wheel's turns since the last call (+: towards
 * you). Returns 1 if the pointer's over the picture. */
static inline int mouse(int m[4])                         { return lx_syscall(29, (int)m, 0); }

/* --- the network ---
 * fetch("http://host[:port]/path", buf, size): the page (its body,
 * without the HTTP headers) into buf -> its length; -1 it couldn't be
 * fetched, -2 the server said no (404...), -3 it's moved: the new
 * address is in buf. As `wget`, but nothing's saved or shown. */
static inline int fetch(const char *url, void *buf, int n) { return lx_syscall3(30, (int)url, (int)buf, n); }

/* font(buf): the system's 8x16 font, 4096 bytes - 256 glyphs, 16 rows
 * each, bit 7 the leftmost pixel (code page 866: Russian letters at
 * 0x80-0xAF and 0xE0-0xF1; Spanish ones at 0xF2-0xF7, 0xFC, 0xFD...). */
static inline void font(void *buf)                        { lx_syscall(31, (int)buf, 0); }

/* keydown(scancode): 1 while that key is held - for games. */
static inline int keydown(int scancode)                   { return lx_syscall(20, scancode, 0); }
#define KEY_ESC   0x01
#define KEY_ENTER 0x1C
#define KEY_SPACE 0x39
#define KEY_UP    0x48
#define KEY_DOWN  0x50
#define KEY_LEFT  0x4B
#define KEY_RIGHT 0x4D
#define KEY_W     0x11
#define KEY_A     0x1E
#define KEY_S     0x1F
#define KEY_D     0x20

/* --- strings and memory ---
 * (weak, not static: the compiler may call memcpy/memset on its own) */
#define LX_LIB __attribute__((weak, used, optimize("no-tree-loop-distribute-patterns")))

LX_LIB void *memset(void *d, int c, size_t n)
{ unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
LX_LIB void *memcpy(void *d, const void *s, size_t n)
{ unsigned char *p = d; const unsigned char *q = s; while (n--) *p++ = *q++; return d; }
LX_LIB void *memmove(void *d, const void *s, size_t n)
{
    unsigned char *p = d; const unsigned char *q = s;
    if (p < q) while (n--) *p++ = *q++;
    else { p += n; q += n; while (n--) *--p = *--q; }
    return d;
}
LX_LIB int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *p = a, *q = b;
    for (; n; n--, p++, q++) if (*p != *q) return *p - *q;
    return 0;
}
LX_LIB size_t strlen(const char *s)            { size_t n = 0; while (s[n]) n++; return n; }
LX_LIB int strcmp(const char *a, const char *b)
{ while (*a && *a == *b) a++, b++; return (unsigned char)*a - (unsigned char)*b; }
LX_LIB char *strcpy(char *d, const char *s)    { char *r = d; while ((*d++ = *s++)); return r; }

static inline void puts(const char *s)        { write(s, strlen(s)); }
static inline void putchar(char c)            { write(&c, 1); }
static inline int  fputs(int fd, const char *s) { return fwrite(fd, s, strlen(s)); }

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

/* --- floating point: float and double work (the x87 FPU; each
 * program has its own registers, kept across task switches). The
 * functions below are single x87 instructions or a few of them. --- */
#define M_PI 3.14159265358979323846
static inline double sqrt(double x)  { double r; __asm__("fsqrt" : "=t"(r) : "0"(x)); return r; }
static inline double sin(double x)   { double r; __asm__("fsin" : "=t"(r) : "0"(x)); return r; }
static inline double cos(double x)   { double r; __asm__("fcos" : "=t"(r) : "0"(x)); return r; }
static inline double tan(double x)   { double r; __asm__("fptan; fstp %%st(0)" : "=t"(r) : "0"(x)); return r; }
static inline double fabs(double x)  { double r; __asm__("fabs" : "=t"(r) : "0"(x)); return r; }
static inline double atan2(double y, double x)
{ double r; __asm__("fpatan" : "=t"(r) : "0"(x), "u"(y) : "st(1)"); return r; }
static inline double atan(double x)  { return atan2(x, 1.0); }
static inline double log(double x)   /* ln x = ln 2 * log2 x */
{ double r; __asm__("fldln2; fxch; fyl2x" : "=t"(r) : "0"(x) : "st(1)"); return r; }
static inline double exp(double x)   /* 2^(x * log2 e), split into integer and fraction */
{
    double r;
    __asm__("fldl2e; fmulp; fld %%st(0); frndint; fsubr %%st, %%st(1); fxch;"
            "f2xm1; fld1; faddp; fscale; fstp %%st(1)" : "=t"(r) : "0"(x));
    return r;
}
static inline double pow(double x, double y) { return x > 0 ? exp(y * log(x)) : 0; }
static inline double floor(double x) { double r = (double)(int)x; return r > x ? r - 1 : r; }
static inline double ceil(double x)  { double r = (double)(int)x; return r < x ? r + 1 : r; }

/* print_float(3.14159, 3) -> "3.142" */
static inline void print_float(double v, int decimals)
{
    int i, whole;
    double scale = 1;
    for (i = 0; i < decimals; i++) scale *= 10;
    if (v < 0) { putchar('-'); v = -v; }
    v += 0.5 / scale;                                   /* round */
    whole = (int)v;
    print_int(whole);
    if (decimals > 0) {
        putchar('.');
        v -= whole;
        for (i = 0; i < decimals; i++) { v *= 10; putchar('0' + (int)v % 10); v -= (int)v; }
    }
}

/* --- malloc/free: first fit over the memory from the program's end
 * (app.ld's _end) up to 256KB below the top, where the stack lives. --- */
#define LX_HEAP_END 0xBC0000
extern char _end[];
struct lx_block { size_t size; int free; struct lx_block *next; int pad; };
struct lx_block *__lx_heap __attribute__((weak));

LX_LIB void *malloc(size_t n)
{
    struct lx_block *b, *last = NULL;
    n = (n + 15) & ~15u;
    for (b = __lx_heap; b; last = b, b = b->next)
        if (b->free && b->size >= n) {
            if (b->size >= n + sizeof *b + 16) {     /* split off the rest */
                struct lx_block *r = (struct lx_block *)((char *)(b + 1) + n);
                r->size = b->size - n - sizeof *b; r->free = 1; r->next = b->next;
                b->size = n; b->next = r;
            }
            b->free = 0;
            return b + 1;
        }
    b = last ? (struct lx_block *)((char *)(last + 1) + last->size)
             : (struct lx_block *)(((unsigned)_end + 15) & ~15u);
    if ((unsigned)(b + 1) + n > LX_HEAP_END) return NULL;
    b->size = n; b->free = 0; b->next = NULL;
    if (last) last->next = b; else __lx_heap = b;
    return b + 1;
}
LX_LIB void free(void *p)
{
    struct lx_block *b;
    if (!p) return;
    ((struct lx_block *)p - 1)->free = 1;
    for (b = __lx_heap; b; b = b->next)             /* merge free neighbors */
        while (b->free && b->next && b->next->free) {
            b->size += sizeof *b + b->next->size;
            b->next = b->next->next;
        }
}
LX_LIB void *calloc(size_t n, size_t m)
{ void *p = malloc(n * m); if (p) memset(p, 0, n * m); return p; }
LX_LIB void *realloc(void *p, size_t n)
{
    void *q;
    if (!p) return malloc(n);
    if (((struct lx_block *)p - 1)->size >= n) return p;
    q = malloc(n);
    if (q) { memcpy(q, p, ((struct lx_block *)p - 1)->size); free(p); }
    return q;
}

/* crt0.asm's helper: splits the command line ("NAME.APP arg1 arg2")
 * into argv, in place. Returns argc. */
LX_LIB int __lx_args(char *cmd, char **argv)
{
    int argc = 0;
    while (*cmd && argc < 31) {
        while (*cmd == ' ') cmd++;
        if (!*cmd) break;
        argv[argc++] = cmd;
        while (*cmd && *cmd != ' ') cmd++;
        if (*cmd) *cmd++ = 0;
    }
    argv[argc] = NULL;
    return argc;
}

#endif
