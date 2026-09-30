/* inflate.h - decompression (inflate, RFC 1951) for LexOS programs in
 * C, and its two wrappers the web uses: gzip (RFC 1952) and zlib
 * (RFC 1950). The whole input at once; the output a byte at a time, to
 * a function of yours:
 *
 *   static int put(int c) { ...; return 0; }      (nonzero: stop there)
 *   int r = gunzip(data, n, put);   / zinflate(data, n, put)
 *                                   / inflate_raw(data, n, put)
 *   -> 0 done, 1 stopped by put, <0 not what it should be
 *
 * The last 32KB of the output are kept (a static window) for the
 * back-references. */
#ifndef INFLATE_H
#define INFLATE_H
#include "lexos.h"

static const unsigned char *if_in;
static int if_n, if_pos, if_bit, if_err, if_stop;
static unsigned char if_win[32768];
static int if_wpos;
static int (*if_put)(int c);
struct if_huff { short count[16], sym[320]; };
static struct if_huff if_lc, if_dc;

static int if_getbit(void)
{
    int b;
    if (if_pos >= if_n) { if_err = 1; return 0; }
    b = if_in[if_pos] >> if_bit & 1;
    if (++if_bit == 8) { if_bit = 0; if_pos++; }
    return b;
}
static int if_bits(int n)
{
    int v = 0, i;
    for (i = 0; i < n; i++) v |= if_getbit() << i;
    return v;
}
static void if_emit(int c)
{
    if_win[if_wpos++ & 32767] = c;
    if (!if_stop && if_put(c)) if_stop = 1;
}
static void if_build(struct if_huff *h, const short *len, int n)
{
    short offs[16];
    int i;
    for (i = 0; i < 16; i++) h->count[i] = 0;
    for (i = 0; i < n; i++) h->count[len[i]]++;
    h->count[0] = 0;
    offs[1] = 0;
    for (i = 1; i < 15; i++) offs[i + 1] = offs[i] + h->count[i];
    for (i = 0; i < n; i++) if (len[i]) h->sym[offs[len[i]]++] = i;
}
static int if_decode(struct if_huff *h)
{
    int code = 0, first = 0, index = 0, len;
    for (len = 1; len < 16; len++) {
        int count;
        code |= if_getbit();
        count = h->count[len];
        if (code - count < first) return h->sym[index + (code - first)];
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
        if (if_err) return -1;
    }
    if_err = 2;
    return -1;
}
static const short if_lbase[29] = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
static const short if_lext[29] = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
static const short if_dbase[30] = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
static const short if_dext[30] = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

static int if_codes(void)
{
    for (;;) {
        int s = if_decode(&if_lc);
        if (s < 0 || if_err) return -1;
        if (s < 256) if_emit(s);
        else if (s == 256) return 0;
        else {
            int len, dist, d;
            s -= 257;
            if (s >= 29) return -1;
            len = if_lbase[s] + if_bits(if_lext[s]);
            d = if_decode(&if_dc);
            if (d < 0 || d >= 30) return -1;
            dist = if_dbase[d] + if_bits(if_dext[d]);
            if (dist > if_wpos) return -1;
            while (len--) if_emit(if_win[(if_wpos - dist) & 32767]);
        }
        if (if_stop) return 0;
    }
}

/* raw deflate data -> put() */
static int inflate_raw(const unsigned char *src, int n, int (*put)(int c))
{
    int last;
    if_in = src; if_n = n; if_pos = 0; if_bit = 0; if_err = 0; if_wpos = 0;
    if_put = put; if_stop = 0;
    do {
        int type;
        last = if_getbit();
        type = if_bits(2);
        if (if_err) return -1;
        if (type == 0) {                                   /* stored */
            int len;
            if (if_bit) { if_bit = 0; if_pos++; }
            if (if_pos + 4 > if_n) return -1;
            len = if_in[if_pos] | if_in[if_pos + 1] << 8;
            if_pos += 4;
            if (if_pos + len > if_n) len = if_n - if_pos;
            while (len-- > 0 && !if_stop) if_emit(if_in[if_pos++]);
        } else if (type == 1) {                            /* fixed codes */
            short l[288], d[30];
            int i;
            for (i = 0; i < 144; i++) l[i] = 8;
            for (; i < 256; i++) l[i] = 9;
            for (; i < 280; i++) l[i] = 7;
            for (; i < 288; i++) l[i] = 8;
            for (i = 0; i < 30; i++) d[i] = 5;
            if_build(&if_lc, l, 288);
            if_build(&if_dc, d, 30);
            if (if_codes() < 0) return -1;
        } else if (type == 2) {                            /* dynamic codes */
            static const unsigned char ord[19] = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
            short lens[320], cl[19];
            int nlen = if_bits(5) + 257, ndist = if_bits(5) + 1, ncode = if_bits(4) + 4, i;
            struct if_huff ch;
            if (nlen > 286 || ndist > 30) return -1;
            for (i = 0; i < 19; i++) cl[i] = 0;
            for (i = 0; i < ncode; i++) cl[ord[i]] = if_bits(3);
            if_build(&ch, cl, 19);
            for (i = 0; i < nlen + ndist;) {
                int s = if_decode(&ch), rep, v;
                if (s < 0) return -1;
                if (s < 16) { lens[i++] = s; continue; }
                if (s == 16) { if (!i) return -1; v = lens[i - 1]; rep = 3 + if_bits(2); }
                else if (s == 17) { v = 0; rep = 3 + if_bits(3); }
                else { v = 0; rep = 11 + if_bits(7); }
                if (i + rep > nlen + ndist) return -1;
                while (rep--) lens[i++] = v;
            }
            if_build(&if_lc, lens, nlen);
            if_build(&if_dc, lens + nlen, ndist);
            if (if_codes() < 0) return -1;
        } else return -1;
        if (if_stop) return 1;
    } while (!last);
    return 0;
}

/* gzip: its header, then deflate */
static int gunzip(const unsigned char *s, int n, int (*put)(int c))
{
    int p = 10, fl;
    if (n < 18 || s[0] != 0x1F || s[1] != 0x8B || s[2] != 8) return -1;
    fl = s[3];
    if (fl & 4) { if (p + 2 > n) return -1; p += 2 + (s[p] | s[p + 1] << 8); }   /* extra */
    if (fl & 8) { while (p < n && s[p]) p++; p++; }                             /* name */
    if (fl & 16) { while (p < n && s[p]) p++; p++; }                            /* comment */
    if (fl & 2) p += 2;                                                         /* crc16 */
    if (p >= n) return -1;
    return inflate_raw(s + p, n - p, put);
}

/* zlib: 2 bytes, then deflate (HTTP's "deflate" - or, from some
 * servers, raw deflate without them) */
static int zinflate(const unsigned char *s, int n, int (*put)(int c))
{
    if (n > 2 && (s[0] & 0x0F) == 8 && ((s[0] << 8) | s[1]) % 31 == 0) return inflate_raw(s + 2, n - 2, put);
    return inflate_raw(s, n, put);
}

#endif
