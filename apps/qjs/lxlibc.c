/* lxlibc.c - the little C library QuickJS needs, for LexOS: printf and
 * friends (into a buffer, or out through write), strtod, the string
 * functions lexos.h doesn't have, the math library (the x87's own
 * sin/cos/atan/log/2^x in 80 bits, rounded to doubles), 64-bit division
 * (what libgcc does elsewhere), the clock and the calendar.
 *
 * Built with QuickJS (inc/ as the system headers), linked into LexOS
 * Web next to browser.c - whose lexos.h has malloc, free, memcpy... */
#include <stddef.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <sys/time.h>
#include "../dtoa.h"

int errno;

static inline int lx_sys3(int n, int a, int b, int c)
{
    int r;
    __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "b"(a), "c"(b), "d"(c) : "memory");
    return r;
}

/* ---- out: what QuickJS prints (its error dumps) - lx_out, if set ---- */
void (*lx_out)(const char *s, int n);
struct lx_file { int fd; };
static struct lx_file f_out = { 1 }, f_err = { 2 }, f_in = { 0 };
FILE *stdout = &f_out, *stderr = &f_err, *stdin = &f_in;

static void out(const char *s, int n) { if (lx_out && n > 0) lx_out(s, n); }

/* ---- memory: whole words at a time (lexos.h's own are a byte at a time) ---- */
void *memcpy(void *d, const void *s, size_t n)
{
    void *r = d;
    size_t w = n >> 2;
    __asm__ volatile("cld; rep movsl" : "+D"(d), "+S"(s), "+c"(w) : : "memory");
    n &= 3;
    __asm__ volatile("rep movsb" : "+D"(d), "+S"(s), "+c"(n) : : "memory");
    return r;
}
void *memmove(void *d, const void *s, size_t n)
{
    unsigned char *p = d;
    const unsigned char *q = s;
    if (p <= q || p >= q + n) return memcpy(d, s, n);
    p += n - 1; q += n - 1;
    __asm__ volatile("std; rep movsb; cld" : "+D"(p), "+S"(q), "+c"(n) : : "memory");
    return d;
}
void *memset(void *d, int c, size_t n)
{
    void *r = d;
    unsigned v = (unsigned char)c * 0x01010101u;
    size_t w = n >> 2;
    __asm__ volatile("cld; rep stosl" : "+D"(d), "+c"(w) : "a"(v) : "memory");
    n &= 3;
    __asm__ volatile("rep stosb" : "+D"(d), "+c"(n) : "a"(v) : "memory");
    return r;
}
int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *p = a, *q = b;
    for (; n >= 4 && *(const unsigned *)p == *(const unsigned *)q; n -= 4, p += 4, q += 4) ;
    for (; n; n--, p++, q++) if (*p != *q) return *p - *q;
    return 0;
}
size_t strlen(const char *s) { const char *p = s; while (*p) p++; return p - s; }

/* ---- strings ---- */
void *memchr(const void *s, int c, size_t n)
{
    const unsigned char *p = s;
    for (; n; n--, p++) if (*p == (unsigned char)c) return (void *)p;
    return 0;
}
char *strchr(const char *s, int c)
{
    for (;; s++) { if (*s == (char)c) return (char *)s; if (!*s) return 0; }
}
char *strrchr(const char *s, int c)
{
    const char *r = 0;
    for (;; s++) { if (*s == (char)c) r = s; if (!*s) return (char *)r; }
}
char *strstr(const char *h, const char *w)
{
    size_t n = strlen(w);
    if (!n) return (char *)h;
    for (; *h; h++) if (*h == *w && !memcmp(h, w, n)) return (char *)h;
    return 0;
}
int strncmp(const char *a, const char *b, size_t n)
{
    for (; n; n--, a++, b++) { if (*a != *b) return (unsigned char)*a - (unsigned char)*b; if (!*a) return 0; }
    return 0;
}
size_t strnlen(const char *s, size_t m) { size_t n = 0; while (n < m && s[n]) n++; return n; }
int abs(int v) { return v < 0 ? -v : v; }
void abort(void)
{
    out("QuickJS: abort\n", 15);
    lx_sys3(0, 1, 0, 0);
    for (;;) ;
}

double strtod(const char *s, char **end)
{
    JSATODTempMem tmp;
    const char *e;
    double d;
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    d = js_atod(s, &e, 10, 0, &tmp);
    if (end) *end = (char *)e;
    return d;
}

/* ---- printf ---- */
struct pf { char *b; size_t n, at; int fd; };
static void pf_put(struct pf *p, const char *s, int n)
{
    int i;
    if (p->b) {
        for (i = 0; i < n; i++, p->at++) if (p->at + 1 < p->n) p->b[p->at] = s[i];
    } else {
        out(s, n);
        p->at += n;
    }
}
static void pf_pad(struct pf *p, int c, int n) { char ch = c; while (n-- > 0) pf_put(p, &ch, 1); }

static int pf_vfmt(struct pf *p, const char *f, va_list ap)
{
    char num[128];
    for (; *f; f++) {
        int left = 0, zero = 0, plus = 0, space = 0, alt = 0, width = 0, prec = -1, lng = 0, len, neg = 0;
        const char *s;
        if (*f != '%') {
            const char *q = f;
            while (*q && *q != '%') q++;
            pf_put(p, f, q - f);
            f = q - 1;
            continue;
        }
        f++;
        for (;; f++) {
            if (*f == '-') left = 1;
            else if (*f == '0') zero = 1;
            else if (*f == '+') plus = 1;
            else if (*f == ' ') space = 1;
            else if (*f == '#') alt = 1;
            else break;
        }
        if (*f == '*') { width = va_arg(ap, int); if (width < 0) { left = 1; width = -width; } f++; }
        else while (*f >= '0' && *f <= '9') width = width * 10 + *f++ - '0';
        if (*f == '.') {
            f++;
            prec = 0;
            if (*f == '*') { prec = va_arg(ap, int); f++; }
            else while (*f >= '0' && *f <= '9') prec = prec * 10 + *f++ - '0';
        }
        for (;; f++) {
            if (*f == 'l') lng++;
            else if (*f == 'h') ;
            else if (*f == 'z' || *f == 't' || *f == 'j') lng = *f == 'j' ? 2 : 1;
            else break;
        }
        s = num;
        switch (*f) {
        case 'd': case 'i': case 'u': case 'x': case 'X': case 'o': case 'p': {
            unsigned long long v;
            int base = *f == 'x' || *f == 'X' || *f == 'p' ? 16 : *f == 'o' ? 8 : 10, i = sizeof num;
            const char *dig = *f == 'X' ? "0123456789ABCDEF" : "0123456789abcdef";
            if (*f == 'p') { v = (uintptr_t)va_arg(ap, void *); alt = 1; }
            else if (*f == 'd' || *f == 'i') {
                long long sv = lng >= 2 ? va_arg(ap, long long) : lng ? va_arg(ap, long) : va_arg(ap, int);
                if (sv < 0) { neg = 1; v = -(unsigned long long)sv; } else v = sv;
            } else v = lng >= 2 ? va_arg(ap, unsigned long long) : lng ? va_arg(ap, unsigned long) : va_arg(ap, unsigned);
            do { num[--i] = dig[v % base]; v /= base; } while (v);
            while (prec >= 0 && (int)sizeof num - i < prec) num[--i] = '0';
            if (alt && base == 16) { num[--i] = *f == 'X' ? 'X' : 'x'; num[--i] = '0'; }
            if (neg) num[--i] = '-'; else if (plus) num[--i] = '+'; else if (space) num[--i] = ' ';
            s = num + i;
            len = sizeof num - i;
            if (prec >= 0) zero = 0;
            break;
        }
        case 'c': num[0] = (char)va_arg(ap, int); len = 1; break;
        case 's':
            s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            len = prec >= 0 ? (int)strnlen(s, prec) : (int)strlen(s);
            zero = 0;
            break;
        case 'f': case 'F': case 'e': case 'E': case 'g': case 'G': case 'a': {
            JSDTOATempMem tmp;
            double d = va_arg(ap, double);
            int fl = *f == 'f' || *f == 'F' ? JS_DTOA_FORMAT_FRAC : JS_DTOA_FORMAT_FIXED;
            if (*f == 'e' || *f == 'E') fl |= JS_DTOA_EXP_ENABLED;
            if (prec < 0) prec = 6;
            if (fl == JS_DTOA_FORMAT_FIXED && prec == 0) prec = 1;
            if (prec > 60) prec = 60;
            len = js_dtoa(num, d, 10, (fl & JS_DTOA_FORMAT_MASK) == JS_DTOA_FORMAT_FRAC ? prec : prec, fl, &tmp);
            if (*f == 'g' || *f == 'G') {           /* (no trailing zeros) */
                int k, dot = -1, e = len;
                for (k = 0; k < len; k++) { if (num[k] == '.') dot = k; if (num[k] == 'e') { e = k; break; } }
                if (dot >= 0 && !alt) {
                    int z = e;
                    while (z > dot + 1 && num[z - 1] == '0') z--;
                    if (z == dot + 1) z = dot;
                    memmove(num + z, num + e, len - e);
                    len -= e - z;
                }
            }
            if (plus && num[0] != '-') { memmove(num + 1, num, len); num[0] = '+'; len++; }
            break;
        }
        case 'n': *va_arg(ap, int *) = p->at; continue;
        case '%': num[0] = '%'; len = 1; break;
        default: num[0] = '%'; num[1] = *f; len = 2; if (!*f) { len = 1; f--; } break;
        }
        if (!left && width > len) {
            if (zero && (*s == '-' || *s == '+')) { pf_put(p, s, 1); s++; len--; width--; }
            pf_pad(p, zero ? '0' : ' ', width - len);
        }
        pf_put(p, s, len);
        if (left && width > len) pf_pad(p, ' ', width - len);
    }
    if (p->b && p->n) p->b[p->at < p->n ? p->at : p->n - 1] = 0;
    return p->at;
}
int vsnprintf(char *b, size_t n, const char *f, va_list ap)
{
    struct pf p = { b, n, 0, -1 };
    if (!b) { static char dummy[1]; p.b = dummy; p.n = 0; }
    return pf_vfmt(&p, f, ap);
}
int snprintf(char *b, size_t n, const char *f, ...)
{
    va_list ap; int r;
    va_start(ap, f); r = vsnprintf(b, n, f, ap); va_end(ap);
    return r;
}
int sprintf(char *b, const char *f, ...)
{
    va_list ap; int r;
    va_start(ap, f); r = vsnprintf(b, 0x7FFFFFFF, f, ap); va_end(ap);
    return r;
}
int vfprintf(FILE *fp, const char *f, va_list ap)
{
    struct pf p = { 0, 0, 0, fp ? fp->fd : 1 };
    return pf_vfmt(&p, f, ap);
}
int fprintf(FILE *fp, const char *f, ...)
{
    va_list ap; int r;
    va_start(ap, f); r = vfprintf(fp, f, ap); va_end(ap);
    return r;
}
int printf(const char *f, ...)
{
    va_list ap; int r;
    va_start(ap, f); r = vfprintf(stdout, f, ap); va_end(ap);
    return r;
}
int putchar(int c) { char ch = c; out(&ch, 1); return c; }
int fputc(int c, FILE *fp) { (void)fp; return putchar(c); }
int putc(int c, FILE *fp) { (void)fp; return putchar(c); }
int fputs(const char *s, FILE *fp) { (void)fp; out(s, strlen(s)); return 0; }
int puts(const char *s) { out(s, strlen(s)); out("\n", 1); return 0; }
size_t fwrite(const void *b, size_t sz, size_t n, FILE *fp) { (void)fp; out(b, sz * n); return n; }
int fflush(FILE *fp) { (void)fp; return 0; }

/* ---- the clock: the RTC (as UTC) when first asked, then the ms since ---- */
static long long t0_ms;
static unsigned t0_millis;
static int t_tz, t_ready;
static long long days_from(int y, int m, int d)
{
    y -= m <= 2;
    {
        int era = (y >= 0 ? y : y - 399) / 400, yoe = y - era * 400;
        int doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
        int doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return (long long)era * 146097 + doe - 719468;
    }
}
static void t_init(void)
{
    unsigned char t[8];
    if (t_ready) return;
    t_ready = 1;
    lx_sys3(48, 8, (int)t, 0);                           /* (lx_op TIME) */
    t_tz = (short)(t[6] | t[7] << 8) * 60;               /* (the kernel keeps it in hours) */
    t0_ms = (days_from(2000 + t[0], t[1] ? t[1] : 1, t[2] ? t[2] : 1) * 86400 + t[3] * 3600 + t[4] * 60 + t[5]) * 1000LL;
    t0_millis = (unsigned)lx_sys3(26, 0, 0, 0);
}
long long lx_now_ms(void)
{
    t_init();
    return t0_ms + (unsigned)((unsigned)lx_sys3(26, 0, 0, 0) - t0_millis);
}
int gettimeofday(struct timeval *tv, void *tz)
{
    long long ms = lx_now_ms();
    (void)tz;
    tv->tv_sec = ms / 1000;
    tv->tv_usec = (long)(ms % 1000) * 1000;
    return 0;
}
int clock_gettime(int id, struct timespec *ts)
{
    long long ms = id == CLOCK_MONOTONIC ? (long long)(unsigned)lx_sys3(26, 0, 0, 0) : lx_now_ms();
    ts->tv_sec = ms / 1000;
    ts->tv_nsec = (long)(ms % 1000) * 1000000;
    return 0;
}
time_t time(time_t *p) { time_t t = lx_now_ms() / 1000; if (p) *p = t; return t; }
struct tm *gmtime_r(const time_t *pt, struct tm *tm)
{
    long long t = *pt, days = t / 86400, rem = t % 86400;
    int y, m, d, doy;
    if (rem < 0) { rem += 86400; days--; }
    tm->tm_hour = rem / 3600; tm->tm_min = rem / 60 % 60; tm->tm_sec = rem % 60;
    tm->tm_wday = (int)((days % 7 + 11) % 7);            /* (1970-01-01: a Thursday) */
    {
        long long z = days + 719468, era = (z >= 0 ? z : z - 146096) / 146097;
        unsigned doe = (unsigned)(z - era * 146097);
        unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        unsigned dy = doe - (365 * yoe + yoe / 4 - yoe / 100), mp = (5 * dy + 2) / 153;
        d = dy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        y = (int)(yoe + era * 400) + (m <= 2);
    }
    doy = (int)(days - days_from(y, 1, 1));
    tm->tm_year = y - 1900; tm->tm_mon = m - 1; tm->tm_mday = d; tm->tm_yday = doy;
    tm->tm_isdst = 0; tm->tm_gmtoff = 0; tm->tm_zone = "UTC";
    return tm;
}
struct tm *localtime_r(const time_t *pt, struct tm *tm)
{
    time_t t;
    t_init();
    t = *pt + t_tz * 60;
    gmtime_r(&t, tm);
    tm->tm_gmtoff = t_tz * 60;
    tm->tm_zone = "";
    return tm;
}

/* ---- 64-bit division (libgcc's, elsewhere) ---- */
unsigned long long __udivmoddi4(unsigned long long a, unsigned long long b, unsigned long long *rem)
{
    unsigned long long q = 0;
    int sh;
    if (!b) { if (rem) *rem = 0; return 0; }
    if (!(a >> 32) && !(b >> 32)) {
        unsigned qa = (unsigned)a / (unsigned)b;
        if (rem) *rem = (unsigned)a - qa * (unsigned)b;
        return qa;
    }
    if (b > a) { if (rem) *rem = a; return 0; }
    sh = __builtin_clzll(b) - __builtin_clzll(a);
    b <<= sh;
    for (; sh >= 0; sh--, b >>= 1) {
        q <<= 1;
        if (a >= b) { a -= b; q |= 1; }
    }
    if (rem) *rem = a;
    return q;
}
unsigned long long __udivdi3(unsigned long long a, unsigned long long b) { return __udivmoddi4(a, b, 0); }
unsigned long long __umoddi3(unsigned long long a, unsigned long long b) { unsigned long long r; __udivmoddi4(a, b, &r); return r; }
long long __divdi3(long long a, long long b)
{
    int neg = (a < 0) ^ (b < 0);
    unsigned long long q = __udivmoddi4(a < 0 ? -(unsigned long long)a : a, b < 0 ? -(unsigned long long)b : b, 0);
    return neg ? -(long long)q : (long long)q;
}
long long __divmoddi4(long long a, long long b, long long *rem)
{
    long long q = __divdi3(a, b);
    if (rem) *rem = a - q * b;
    return q;
}
long long __moddi3(long long a, long long b)
{
    unsigned long long r;
    __udivmoddi4(a < 0 ? -(unsigned long long)a : a, b < 0 ? -(unsigned long long)b : b, &r);
    return a < 0 ? -(long long)r : (long long)r;
}

/* ================================================================
 * math: the x87 does the hard part, in 80 bits
 * ================================================================ */
typedef long double ld;
double fmod(double, double);
double trunc(double);
union dbits { double d; uint64_t u; };
static inline uint64_t bits(double d) { union dbits b; b.d = d; return b.u; }
static inline double from_bits(uint64_t u) { union dbits b; b.u = u; return b.d; }
#define NANV __builtin_nan("")
#define INFV __builtin_inf()
static inline int is_nan(double x) { return (bits(x) & 0x7FFFFFFFFFFFFFFFULL) > 0x7FF0000000000000ULL; }
static inline int is_inf(double x) { return (bits(x) & 0x7FFFFFFFFFFFFFFFULL) == 0x7FF0000000000000ULL; }

double fabs(double x) { return from_bits(bits(x) & 0x7FFFFFFFFFFFFFFFULL); }
double copysign(double x, double y) { return from_bits((bits(x) & 0x7FFFFFFFFFFFFFFFULL) | (bits(y) & 0x8000000000000000ULL)); }
double sqrt(double x) { return __builtin_sqrt(x); }

static ld x87_rnd(ld x, unsigned short mode)
{
    unsigned short cw, ncw;
    ld r;
    __asm__ volatile("fnstcw %0" : "=m"(cw));
    ncw = (cw & ~0x0C00) | mode;
    __asm__ volatile("fldcw %0" : : "m"(ncw));
    __asm__ volatile("frndint" : "=t"(r) : "0"(x));
    __asm__ volatile("fldcw %0" : : "m"(cw));
    return r;
}
static double rnd(double x, unsigned short mode)
{
    if (is_nan(x) || is_inf(x) || fabs(x) >= 4503599627370496.0) return x;
    return copysign((double)x87_rnd(x, mode), x);             /* (-0.5 -> -0) */
}
double floor(double x) { return rnd(x, 0x0400); }
double ceil(double x) { return rnd(x, 0x0800); }
double trunc(double x) { return rnd(x, 0x0C00); }
double rint(double x) { return rnd(x, 0); }
double nearbyint(double x) { return rnd(x, 0); }
double round(double x)
{
    double t = trunc(x);
    if (fabs(x - t) >= 0.5) t += copysign(1.0, x);
    return t;
}
long lrint(double x) { long r; ld v = x; __asm__("fistpl %0" : "=m"(r) : "t"(v) : "st"); return r; }
long long llrint(double x) { long long r; ld v = x; __asm__("fistpll %0" : "=m"(r) : "t"(v) : "st"); return r; }

double scalbn(double x, int n)
{
    ld r, e = n;
    if (n > 3000) e = 3000; else if (n < -3000) e = -3000;
    __asm__("fscale" : "=t"(r) : "0"((ld)x), "u"(e));
    return (double)r;
}
double ldexp(double x, int n) { return scalbn(x, n); }
double frexp(double x, int *e)
{
    uint64_t u = bits(x);
    int ex = (int)(u >> 52 & 0x7FF);
    if (!ex) {
        if (x == 0) { *e = 0; return x; }
        x = frexp(x * 18014398509481984.0, e);          /* (2^54: a subnormal's made normal) */
        *e -= 54;
        return x;
    }
    if (ex == 0x7FF) { *e = 0; return x; }
    *e = ex - 1022;
    return from_bits((u & 0x800FFFFFFFFFFFFFULL) | 0x3FE0000000000000ULL);
}
double modf(double x, double *ip)
{
    double t = trunc(x);
    *ip = t;
    return is_inf(x) ? copysign(0.0, x) : copysign(x - t, x);
}

static ld x87_2pow(ld t)                                /* 2^t */
{
    ld i, f, r;
    i = x87_rnd(t, 0);
    f = t - i;                                            /* |f| <= 0.5 */
    __asm__("f2xm1" : "=t"(r) : "0"(f));
    r += 1;
    __asm__("fscale" : "=t"(r) : "0"(r), "u"(i));
    return r;
}
static ld x87_log2(ld x) { ld r; __asm__("fld1; fxch; fyl2x" : "=t"(r) : "0"(x)); return r; }
double exp(double x)
{
    if (is_nan(x)) return x;
    if (x > 710) return INFV;
    if (x < -746) return 0;
    return (double)x87_2pow((ld)x * 1.44269504088896340735992468100189214L);
}
double exp2(double x)
{
    if (is_nan(x)) return x;
    if (x > 1025) return INFV;
    if (x < -1080) return 0;
    return (double)x87_2pow(x);
}
double expm1(double x)
{
    if (is_nan(x)) return x;
    if (fabs(x) < 0.5) {
        ld t = (ld)x * 1.44269504088896340735992468100189214L, r;
        __asm__("f2xm1" : "=t"(r) : "0"(t));
        return (double)r;
    }
    if (x < -40) return -1;
    if (x > 710) return INFV;
    return (double)(x87_2pow((ld)x * 1.44269504088896340735992468100189214L) - 1);
}
double log(double x)
{
    ld r;
    if (is_nan(x) || x < 0) return NANV;
    if (x == 0) return -INFV;
    if (is_inf(x)) return x;
    __asm__("fldln2; fxch; fyl2x" : "=t"(r) : "0"((ld)x));
    return (double)r;
}
double log2(double x)
{
    if (is_nan(x) || x < 0) return NANV;
    if (x == 0) return -INFV;
    if (is_inf(x)) return x;
    return (double)x87_log2(x);
}
double log10(double x)
{
    ld r;
    if (is_nan(x) || x < 0) return NANV;
    if (x == 0) return -INFV;
    if (is_inf(x)) return x;
    __asm__("fldlg2; fxch; fyl2x" : "=t"(r) : "0"((ld)x));
    {                                                     /* (exact powers of ten come out exact) */
        double d = (double)r, k = round(d);
        if (fabs(d - k) < 1e-12 && k >= 0 && k <= 22) {
            double p = 1; int i;
            for (i = 0; i < (int)k; i++) p *= 10;
            if (p == x) return k;
        }
        return d;
    }
}
double log1p(double x)
{
    ld r;
    if (is_nan(x) || x < -1) return NANV;
    if (x == -1) return -INFV;
    if (is_inf(x)) return x;
    if (fabs(x) < 0.29) { __asm__("fldln2; fxch; fyl2xp1" : "=t"(r) : "0"((ld)x)); return (double)r; }
    return log(1 + x);
}

double pow(double x, double y)
{
    int yint, yodd = 0;
    if (y == 0) return 1;
    if (x == 1) return 1;
    if (is_nan(x) || is_nan(y)) return NANV;
    yint = trunc(y) == y;
    if (yint && fabs(y) < 9007199254740992.0) yodd = fmod(fabs(y), 2) == 1;
    if (is_inf(y)) {
        double ax = fabs(x);
        if (ax == 1) return 1;
        return (ax > 1) == (y > 0) ? INFV : 0;
    }
    if (is_inf(x)) {
        if (x > 0) return y > 0 ? INFV : 0;
        return y > 0 ? (yodd ? -INFV : INFV) : (yodd ? -0.0 : 0);
    }
    if (x == 0) {
        if (y > 0) return yodd ? x : 0;
        return yodd ? copysign(INFV, x) : INFV;
    }
    if (x < 0 && !yint) return NANV;
    if (yint && fabs(y) <= 4096) {                        /* (by squaring, in 80 bits) */
        unsigned n = (unsigned)fabs(y);
        ld b = x, r = 1;
        while (n) { if (n & 1) r *= b; b *= b; n >>= 1; }
        if (y < 0) r = 1 / r;
        return (double)r;
    }
    {
        ld t = (ld)y * x87_log2(fabs(x)), r;
        if (t > 1100) r = INFV;
        else if (t < -1100) r = 0;
        else r = x87_2pow(t);
        return (double)(x < 0 && yodd ? -r : r);
    }
}
double cbrt(double x)
{
    double r;
    if (x == 0 || is_nan(x) || is_inf(x)) return x;
    r = pow(fabs(x), 1.0 / 3);
    r = r - (r * r * r - fabs(x)) / (3 * r * r);
    return copysign(r, x);
}
double hypot(double x, double y)
{
    ld s, r;
    if (is_inf(x) || is_inf(y)) return INFV;
    if (is_nan(x) || is_nan(y)) return NANV;
    s = (ld)x * x + (ld)y * y;
    __asm__("fsqrt" : "=t"(r) : "0"(s));
    return (double)r;
}
double fmod(double x, double y)
{
    ld r;
    if (is_nan(x) || is_nan(y) || is_inf(x) || y == 0) return NANV;
    if (is_inf(y)) return x;
    __asm__("1: fprem\n\tfnstsw %%ax\n\ttestw $0x400, %%ax\n\tjnz 1b" : "=t"(r) : "0"((ld)x), "u"((ld)y) : "ax", "cc");
    return copysign((double)r, x);
}

static ld x87_reduce(double x)                           /* (fsin/fcos want |x| < 2^63) */
{
    if (fabs(x) < 9.2e18) return x;
    return fmod(x, 6.283185307179586476925286766559);
}
double sin(double x)
{
    ld r;
    if (is_nan(x) || is_inf(x)) return NANV;
    if (x == 0) return x;
    __asm__("fsin" : "=t"(r) : "0"(x87_reduce(x)));
    return (double)r;
}
double cos(double x)
{
    ld r;
    if (is_nan(x) || is_inf(x)) return NANV;
    __asm__("fcos" : "=t"(r) : "0"(x87_reduce(x)));
    return (double)r;
}
double tan(double x)
{
    ld r;
    if (is_nan(x) || is_inf(x)) return NANV;
    if (x == 0) return x;
    __asm__("fptan; fstp %%st(0)" : "=t"(r) : "0"(x87_reduce(x)));
    return (double)r;
}
double atan2(double y, double x)
{
    ld r;
    if (is_nan(x) || is_nan(y)) return NANV;
    __asm__("fpatan" : "=t"(r) : "0"((ld)x), "u"((ld)y) : "st(1)");
    return (double)r;
}
double atan(double x) { if (x == 0) return x; return atan2(x, 1.0); }
double asin(double x)
{
    if (is_nan(x) || fabs(x) > 1) return NANV;
    if (x == 0) return x;
    {
        ld s = (1 - (ld)x) * (1 + (ld)x), r;
        __asm__("fsqrt" : "=t"(r) : "0"(s));
        return atan2(x, (double)r);
    }
}
double acos(double x)
{
    if (is_nan(x) || fabs(x) > 1) return NANV;
    {
        ld s = (1 - (ld)x) * (1 + (ld)x), r;
        __asm__("fsqrt" : "=t"(r) : "0"(s));
        return atan2((double)r, x);
    }
}
double sinh(double x)
{
    double a = fabs(x), t;
    if (is_nan(x) || is_inf(x) || x == 0) return x;
    if (a > 710) { t = exp(a / 2); return copysign(t / 2 * t, x); }
    t = expm1(a);
    return copysign((t + t / (t + 1)) / 2, x);
}
double cosh(double x)
{
    double a = fabs(x), t;
    if (is_nan(x)) return x;
    if (a > 710) { t = exp(a / 2); return t / 2 * t; }
    t = exp(a);
    return (t + 1 / t) / 2;
}
double tanh(double x)
{
    double a = fabs(x), t;
    if (is_nan(x) || x == 0) return x;
    if (a > 22) return copysign(1.0, x);
    t = expm1(2 * a);
    return copysign(t / (t + 2), x);
}
double asinh(double x)
{
    double a = fabs(x);
    if (is_nan(x) || is_inf(x) || x == 0) return x;
    if (a > 268435456.0) return copysign(log(a) + 0.693147180559945309417232121458, x);
    return copysign(log1p(a + a * a / (1 + sqrt(1 + a * a))), x);
}
double acosh(double x)
{
    if (is_nan(x) || x < 1) return NANV;
    if (x > 268435456.0) return log(x) + 0.693147180559945309417232121458;
    return log1p(x - 1 + sqrt((x - 1) * (x + 1)));
}
double atanh(double x)
{
    double a = fabs(x);
    if (is_nan(x) || a > 1) return NANV;
    if (a == 1) return copysign(INFV, x);
    if (x == 0) return x;
    return copysign(0.5 * log1p(2 * a / (1 - a)), x);
}
double fmin(double a, double b) { return is_nan(a) ? b : is_nan(b) ? a : a < b ? a : b; }
double fmax(double a, double b) { return is_nan(a) ? b : is_nan(b) ? a : a > b ? a : b; }
