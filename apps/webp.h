/* webp.h - WebP pictures: lossy (VP8), lossless (VP8L), with an alpha
 * channel (ALPH) or not, and the first frame of an animated one.
 *
 *   unsigned *webp_load(buf, n, max_w, max_h, bg, &w, &h)
 *
 * -> 0xRRGGBB pixels (malloc'd; transparent parts mixed with bg), made
 * smaller to fit max_w x max_h; or 0 if it isn't a WebP it can read.
 * webp_size(buf, n, &w, &h) -> 1 and its size, without decoding.
 *
 * The decoding is a C rendering of Go's golang.org/x/image/vp8 and
 * vp8l (Copyright 2011-2014 The Go Authors; BSD-style license: its
 * terms - redistribution with this notice kept - apply to this file's
 * decoding parts). */
#ifndef WEBP_H
#define WEBP_H
#include "lexos.h"

/* ================================================================
 * VP8L - lossless
 * ================================================================ */
struct wl_node { unsigned symbol; int children; };       /* children: -1 a leaf, 0 not yet */
struct wl_tree { struct wl_node *nodes; int n, cap; unsigned lut[128]; };
struct wl_dec { const unsigned char *b; int n, at; unsigned bits, nbits; int bad; };

static const unsigned char wl_rev[256] = {
    0x00,0x80,0x40,0xc0,0x20,0xa0,0x60,0xe0,0x10,0x90,0x50,0xd0,0x30,0xb0,0x70,0xf0,
    0x08,0x88,0x48,0xc8,0x28,0xa8,0x68,0xe8,0x18,0x98,0x58,0xd8,0x38,0xb8,0x78,0xf8,
    0x04,0x84,0x44,0xc4,0x24,0xa4,0x64,0xe4,0x14,0x94,0x54,0xd4,0x34,0xb4,0x74,0xf4,
    0x0c,0x8c,0x4c,0xcc,0x2c,0xac,0x6c,0xec,0x1c,0x9c,0x5c,0xdc,0x3c,0xbc,0x7c,0xfc,
    0x02,0x82,0x42,0xc2,0x22,0xa2,0x62,0xe2,0x12,0x92,0x52,0xd2,0x32,0xb2,0x72,0xf2,
    0x0a,0x8a,0x4a,0xca,0x2a,0xaa,0x6a,0xea,0x1a,0x9a,0x5a,0xda,0x3a,0xba,0x7a,0xfa,
    0x06,0x86,0x46,0xc6,0x26,0xa6,0x66,0xe6,0x16,0x96,0x56,0xd6,0x36,0xb6,0x76,0xf6,
    0x0e,0x8e,0x4e,0xce,0x2e,0xae,0x6e,0xee,0x1e,0x9e,0x5e,0xde,0x3e,0xbe,0x7e,0xfe,
    0x01,0x81,0x41,0xc1,0x21,0xa1,0x61,0xe1,0x11,0x91,0x51,0xd1,0x31,0xb1,0x71,0xf1,
    0x09,0x89,0x49,0xc9,0x29,0xa9,0x69,0xe9,0x19,0x99,0x59,0xd9,0x39,0xb9,0x79,0xf9,
    0x05,0x85,0x45,0xc5,0x25,0xa5,0x65,0xe5,0x15,0x95,0x55,0xd5,0x35,0xb5,0x75,0xf5,
    0x0d,0x8d,0x4d,0xcd,0x2d,0xad,0x6d,0xed,0x1d,0x9d,0x5d,0xdd,0x3d,0xbd,0x7d,0xfd,
    0x03,0x83,0x43,0xc3,0x23,0xa3,0x63,0xe3,0x13,0x93,0x53,0xd3,0x33,0xb3,0x73,0xf3,
    0x0b,0x8b,0x4b,0xcb,0x2b,0xab,0x6b,0xeb,0x1b,0x9b,0x5b,0xdb,0x3b,0xbb,0x7b,0xfb,
    0x07,0x87,0x47,0xc7,0x27,0xa7,0x67,0xe7,0x17,0x97,0x57,0xd7,0x37,0xb7,0x77,0xf7,
    0x0f,0x8f,0x4f,0xcf,0x2f,0xaf,0x6f,0xef,0x1f,0x9f,0x5f,0xdf,0x3f,0xbf,0x7f,0xff };

static unsigned wl_read(struct wl_dec *d, unsigned n)
{
    unsigned u;
    while (d->nbits < n) {
        if (d->at >= d->n) { d->bad = 1; return 0; }
        d->bits |= (unsigned)d->b[d->at++] << d->nbits;
        d->nbits += 8;
    }
    u = n == 32 ? d->bits : d->bits & ((1u << n) - 1);
    d->bits = n == 32 ? 0 : d->bits >> n;
    d->nbits -= n;
    return u;
}

static void wl_tree_free(struct wl_tree *h) { free(h->nodes); h->nodes = 0; }

static int wl_insert(struct wl_tree *h, unsigned symbol, unsigned code, unsigned len)
{
    unsigned base = 0, n = 0;
    int jump = 7;
    if (symbol > 0xffff || len > 0xfe) return 0;
    if (len > 7) base = (unsigned)wl_rev[(code >> (len - 7)) & 0xff] >> 1;
    else {
        int i;
        base = (unsigned)wl_rev[code & 0xff] >> (8 - len);
        for (i = 0; i < 1 << (7 - len); i++) h->lut[base | (unsigned)i << len] = symbol << 8 | (len + 1);
    }
    while (len > 0) {
        len--;
        if ((int)n >= h->n) return 0;
        if (h->nodes[n].children == -1) return 0;
        if (h->nodes[n].children == 0) {
            if (h->n + 2 > h->cap) return 0;
            h->nodes[n].children = h->n;
            h->nodes[h->n].symbol = 0; h->nodes[h->n].children = 0;
            h->nodes[h->n + 1].symbol = 0; h->nodes[h->n + 1].children = 0;
            h->n += 2;
        }
        n = (unsigned)h->nodes[n].children + (1 & (code >> len));
        jump--;
        if (jump == 0 && h->lut[base] == 0) h->lut[base] = n << 8;
    }
    if (h->nodes[n].children == 0) h->nodes[n].children = -1;
    else if (h->nodes[n].children != -1) return 0;
    h->nodes[n].symbol = symbol;
    return 1;
}

static int wl_tree_init(struct wl_tree *h, int nsym)
{
    h->cap = 2 * nsym + 1;
    h->nodes = malloc(h->cap * sizeof *h->nodes);
    if (!h->nodes) return 0;
    h->n = 1;
    h->nodes[0].symbol = 0;
    h->nodes[0].children = 0;
    memset(h->lut, 0, sizeof h->lut);
    return 1;
}

static int wl_build(struct wl_tree *h, const unsigned *lens, int count)
{
    int nsym = 0, last = 0, i, cl;
    unsigned hist[16], next[16], cur = 0;
    for (i = 0; i < count; i++) if (lens[i]) { nsym++; last = i; }
    if (!nsym) return 0;
    if (!wl_tree_init(h, nsym)) return 0;
    if (nsym == 1) return wl_insert(h, last, 0, 0);
    memset(hist, 0, sizeof hist);
    for (i = 0; i < count; i++) { if (lens[i] > 15) return 0; hist[lens[i]]++; }
    next[0] = 0;
    for (cl = 1; cl < 16; cl++) { cur = (cur + hist[cl - 1]) << 1; next[cl] = cur; }
    for (i = 0; i < count; i++)
        if (lens[i] && !wl_insert(h, i, next[lens[i]]++, lens[i])) return 0;
    return 1;
}

static unsigned wl_next(struct wl_tree *h, struct wl_dec *d)
{
    unsigned n;
    if (d->nbits < 7 && d->at < d->n) { d->bits |= (unsigned)d->b[d->at++] << d->nbits; d->nbits += 8; }
    if (d->nbits >= 7) {
        n = h->lut[d->bits & 127];
        if (n & 0xff) {
            unsigned b = (n & 0xff) - 1;
            d->bits >>= b;
            d->nbits -= b;
            return n >> 8;
        }
        n >>= 8;
        d->bits >>= 7;
        d->nbits -= 7;
    } else n = 0;
    while (h->nodes[n].children != -1) {
        if (d->nbits == 0) {
            if (d->at >= d->n) { d->bad = 1; return 0; }
            d->bits = d->b[d->at++];
            d->nbits = 8;
        }
        n = (unsigned)h->nodes[n].children + (1 & d->bits);
        d->bits >>= 1;
        d->nbits--;
        if ((int)n >= h->n) { d->bad = 1; return 0; }
    }
    return h->nodes[n].symbol;
}

static int wl_code_lengths(struct wl_dec *d, unsigned *dst, int count, const unsigned *cllens)
{
    static const unsigned char rbits[3] = { 2, 3, 7 }, roff[3] = { 3, 3, 11 };
    struct wl_tree h;
    int maxsym = count, sym = 0;
    unsigned prev = 8;
    if (!wl_build(&h, cllens, 19)) { wl_tree_free(&h); return 0; }
    if (wl_read(d, 1)) {
        unsigned nb = 2 + 2 * wl_read(d, 3);
        maxsym = wl_read(d, nb) + 2;
        if (maxsym > count) { wl_tree_free(&h); return 0; }
    }
    while (sym < count) {
        unsigned cl, rep, v;
        if (maxsym == 0) break;
        maxsym--;
        cl = wl_next(&h, d);
        if (d->bad) break;
        if (cl < 16) {
            dst[sym++] = cl;
            if (cl) prev = cl;
            continue;
        }
        rep = wl_read(d, rbits[cl - 16]) + roff[cl - 16];
        if (sym + (int)rep > count) { wl_tree_free(&h); return 0; }
        v = cl == 16 ? prev : 0;
        while (rep--) dst[sym++] = v;
    }
    wl_tree_free(&h);
    return !d->bad;
}

static int wl_read_tree(struct wl_dec *d, struct wl_tree *h, int alpha_size)
{
    static const unsigned char order[19] = { 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    if (wl_read(d, 1)) {                                 /* a simple code: 1 or 2 symbols */
        unsigned ns = wl_read(d, 1) + 1, first = wl_read(d, 1) * 7 + 1, s[2], i;
        s[0] = wl_read(d, first);
        s[1] = ns == 2 ? wl_read(d, 8) : 0;
        if (!wl_tree_init(h, ns)) return 0;
        for (i = 0; i < ns; i++) {
            if ((int)s[i] >= alpha_size) return 0;
            if (!wl_insert(h, s[i], i, ns - 1)) return 0;
        }
        return !d->bad;
    }
    {
        unsigned ncodes = wl_read(d, 4) + 4, cll[19], i;
        unsigned *lens;
        int ok;
        if (ncodes > 19) return 0;
        memset(cll, 0, sizeof cll);
        for (i = 0; i < ncodes; i++) cll[order[i]] = wl_read(d, 3);
        lens = malloc(alpha_size * sizeof *lens);
        if (!lens) return 0;
        memset(lens, 0, alpha_size * sizeof *lens);
        ok = wl_code_lengths(d, lens, alpha_size, cll) && wl_build(h, lens, alpha_size);
        free(lens);
        return ok;
    }
}

static int wl_tiles(int size, int bits) { return (size + (1 << bits) - 1) >> bits; }

static unsigned wl_lz77(struct wl_dec *d, unsigned sym)
{
    unsigned extra, off;
    if (sym < 4) return sym + 1;
    extra = (sym - 2) >> 1;
    off = (2 + (sym & 1)) << extra;
    return off + wl_read(d, extra) + 1;
}

static const unsigned char wl_dist_map[120] = {
    0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1a, 0x26, 0x2a, 0x38, 0x05, 0x37, 0x39, 0x15, 0x1b, 0x36, 0x3a,
    0x25, 0x2b, 0x48, 0x04, 0x47, 0x49, 0x14, 0x1c, 0x35, 0x3b, 0x46, 0x4a, 0x24, 0x2c, 0x58, 0x45, 0x4b, 0x34, 0x3c, 0x03,
    0x57, 0x59, 0x13, 0x1d, 0x56, 0x5a, 0x23, 0x2d, 0x44, 0x4c, 0x55, 0x5b, 0x33, 0x3d, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1e,
    0x66, 0x6a, 0x22, 0x2e, 0x54, 0x5c, 0x43, 0x4d, 0x65, 0x6b, 0x32, 0x3e, 0x78, 0x01, 0x77, 0x79, 0x53, 0x5d, 0x11, 0x1f,
    0x64, 0x6c, 0x42, 0x4e, 0x76, 0x7a, 0x21, 0x2f, 0x75, 0x7b, 0x31, 0x3f, 0x63, 0x6d, 0x52, 0x5e, 0x00, 0x74, 0x7c, 0x41,
    0x4f, 0x10, 0x20, 0x62, 0x6e, 0x30, 0x73, 0x7d, 0x51, 0x5f, 0x40, 0x72, 0x7e, 0x61, 0x6f, 0x50, 0x71, 0x7f, 0x60, 0x70 };

static int wl_dist(int w, unsigned code)
{
    int dc, d;
    if (code > 120) return (int)code - 120;
    dc = wl_dist_map[code - 1];
    d = (dc >> 4) * w + 8 - (dc & 15);
    return d >= 1 ? d : 1;
}

/* the pixels (R, G, B, A bytes) of an image w x h, entropy-coded; min_cap
 * bytes at least are allocated */
static unsigned char *wl_pix(struct wl_dec *d, int w, int h, int min_cap, int top)
{
    static const int asizes[5] = { 256 + 24, 256, 256, 256, 40 };
    unsigned cc_bits = 0, cc_shift = 0, *cc = 0;
    int ngroups = 1, hbits = 0, hmask = 0, tpr = 0, i, j, p = 0, cp = 0, x = 0, y = 0, len, lookup;
    unsigned char *hpix = 0, *pix = 0;
    struct wl_tree (*groups)[5] = 0, *hg;
    if (wl_read(d, 1)) {
        cc_bits = wl_read(d, 4);
        if (cc_bits < 1 || cc_bits > 11) return 0;
        cc_shift = 32 - cc_bits;
        cc = malloc(sizeof(unsigned) << cc_bits);
        if (!cc) return 0;
        memset(cc, 0, sizeof(unsigned) << cc_bits);
    }
    if (top && wl_read(d, 1)) {                          /* meta prefix codes */
        hbits = wl_read(d, 3) + 2;
        hpix = wl_pix(d, wl_tiles(w, hbits), wl_tiles(h, hbits), 0, 0);
        if (!hpix) goto fail;
        for (i = 0; i < wl_tiles(w, hbits) * wl_tiles(h, hbits) * 4; i += 4) {
            int g = hpix[i] << 8 | hpix[i + 1];
            if (g + 1 > ngroups) ngroups = g + 1;
        }
    }
    groups = malloc(ngroups * sizeof *groups);
    if (!groups) goto fail;
    memset(groups, 0, ngroups * sizeof *groups);
    for (i = 0; i < ngroups; i++)
        for (j = 0; j < 5; j++) {
            int as = asizes[j];
            if (j == 0 && cc_bits) as += 1 << cc_bits;
            if (!wl_read_tree(d, &groups[i][j], as) || d->bad) goto fail;
        }
    if (hbits) { hmask = (1 << hbits) - 1; tpr = wl_tiles(w, hbits); }
    len = 4 * w * h;
    pix = malloc(len > min_cap ? len : min_cap);
    if (!pix) goto fail;
    hg = groups[0];
    lookup = hmask != 0;
    while (p < len) {
        unsigned g;
        if (lookup) {
            int k = 4 * (tpr * (y >> hbits) + (x >> hbits));
            hg = groups[hpix[k] << 8 | hpix[k + 1]];
        }
        g = wl_next(&hg[0], d);
        if (d->bad) goto fail;
        if (g < 256) {
            pix[p + 0] = wl_next(&hg[1], d);
            pix[p + 1] = g;
            pix[p + 2] = wl_next(&hg[2], d);
            pix[p + 3] = wl_next(&hg[3], d);
            p += 4;
            if (++x == w) { x = 0; y++; }
            lookup = hmask && !(x & hmask);
        } else if (g < 256 + 24) {
            unsigned length = wl_lz77(d, g - 256), dsym = wl_next(&hg[4], d), dcode = wl_lz77(d, dsym);
            int dist = wl_dist(w, dcode), pend = p + 4 * (int)length, q = p - 4 * dist;
            if (d->bad || pend > len || q < 0) goto fail;
            for (; p < pend; p++, q++) pix[p] = pix[q];
            x += length;
            while (x >= w) { x -= w; y++; }
            lookup = hmask != 0;
        } else {
            unsigned argb;
            for (; cp < p; cp += 4) {
                argb = (unsigned)pix[cp] << 16 | (unsigned)pix[cp + 1] << 8 | pix[cp + 2] | (unsigned)pix[cp + 3] << 24;
                cc[(argb * 0x1e35a7bdu) >> cc_shift] = argb;
            }
            g -= 256 + 24;
            if (!cc || g >= 1u << cc_bits) goto fail;
            argb = cc[g];
            pix[p + 0] = argb >> 16; pix[p + 1] = argb >> 8; pix[p + 2] = argb; pix[p + 3] = argb >> 24;
            p += 4;
            if (++x == w) { x = 0; y++; }
            lookup = hmask && !(x & hmask);
        }
    }
    for (i = 0; i < ngroups; i++) for (j = 0; j < 5; j++) wl_tree_free(&groups[i][j]);
    free(groups); free(hpix); free(cc);
    return pix;
fail:
    if (groups) { for (i = 0; i < ngroups; i++) for (j = 0; j < 5; j++) wl_tree_free(&groups[i][j]); free(groups); }
    free(hpix); free(cc); free(pix);
    return 0;
}

struct wl_tf { int type, old_w, bits; unsigned char *pix; };

static unsigned char wl_avg2(unsigned char a, unsigned char b) { return (a + b) / 2; }
static unsigned char wl_caf(int a, int b, int c) { int x = a + b - c; return x < 0 ? 0 : x > 255 ? 255 : x; }
static unsigned char wl_cah(int a, int b) { int x = a + (a - b) / 2; return x < 0 ? 0 : x > 255 ? 255 : x; }
static int wl_abs(int x) { return x < 0 ? -x : x; }

static void wl_inv_predictor(struct wl_tf *t, unsigned char *pix, int h)
{
    int p = 4, x, y, top = 0, tpr = wl_tiles(t->old_w, t->bits), mask = (1 << t->bits) - 1, k;
    if (!t->old_w || !h) return;
    pix[3] += 0xff;
    for (x = 1; x < t->old_w; x++, p += 4) for (k = 0; k < 4; k++) pix[p + k] += pix[p - 4 + k];
    for (y = 1; y < h; y++) {
        int q = 4 * (y >> t->bits) * tpr, mode;
        for (k = 0; k < 4; k++) pix[p + k] += pix[top + k];
        p += 4; top += 4;
        mode = t->pix[q + 1] & 15;
        q += 4;
        for (x = 1; x < t->old_w; x++, p += 4, top += 4) {
            if (!(x & mask)) { mode = t->pix[q + 1] & 15; q += 4; }
            switch (mode) {
            case 0: pix[p + 3] += 0xff; break;
            case 1: for (k = 0; k < 4; k++) pix[p + k] += pix[p - 4 + k]; break;
            case 2: for (k = 0; k < 4; k++) pix[p + k] += pix[top + k]; break;
            case 3: for (k = 0; k < 4; k++) pix[p + k] += pix[top + 4 + k]; break;
            case 4: for (k = 0; k < 4; k++) pix[p + k] += pix[top - 4 + k]; break;
            case 5: for (k = 0; k < 4; k++) pix[p + k] += wl_avg2(wl_avg2(pix[p - 4 + k], pix[top + 4 + k]), pix[top + k]); break;
            case 6: for (k = 0; k < 4; k++) pix[p + k] += wl_avg2(pix[p - 4 + k], pix[top - 4 + k]); break;
            case 7: for (k = 0; k < 4; k++) pix[p + k] += wl_avg2(pix[p - 4 + k], pix[top + k]); break;
            case 8: for (k = 0; k < 4; k++) pix[p + k] += wl_avg2(pix[top - 4 + k], pix[top + k]); break;
            case 9: for (k = 0; k < 4; k++) pix[p + k] += wl_avg2(pix[top + k], pix[top + 4 + k]); break;
            case 10:
                for (k = 0; k < 4; k++)
                    pix[p + k] += wl_avg2(wl_avg2(pix[p - 4 + k], pix[top - 4 + k]), wl_avg2(pix[top + k], pix[top + 4 + k]));
                break;
            case 11: {
                int l = 0, tt = 0;
                for (k = 0; k < 4; k++) {
                    l += wl_abs(pix[top - 4 + k] - pix[top + k]);
                    tt += wl_abs(pix[top - 4 + k] - pix[p - 4 + k]);
                }
                if (l < tt) for (k = 0; k < 4; k++) pix[p + k] += pix[p - 4 + k];
                else for (k = 0; k < 4; k++) pix[p + k] += pix[top + k];
                break;
            }
            case 12: for (k = 0; k < 4; k++) pix[p + k] += wl_caf(pix[p - 4 + k], pix[top + k], pix[top - 4 + k]); break;
            case 13: for (k = 0; k < 4; k++) pix[p + k] += wl_cah(wl_avg2(pix[p - 4 + k], pix[top + k]), pix[top - 4 + k]); break;
            }
        }
    }
}

static void wl_inv_cross(struct wl_tf *t, unsigned char *pix, int h)
{
    int g2r = 0, g2b = 0, r2b = 0, p = 0, x, y, mask = (1 << t->bits) - 1, tpr = wl_tiles(t->old_w, t->bits);
    for (y = 0; y < h; y++) {
        int q = 4 * (y >> t->bits) * tpr;
        for (x = 0; x < t->old_w; x++, p += 4) {
            unsigned char r, g, b;
            if (!(x & mask)) {
                r2b = (signed char)t->pix[q + 0];
                g2b = (signed char)t->pix[q + 1];
                g2r = (signed char)t->pix[q + 2];
                q += 4;
            }
            r = pix[p]; g = pix[p + 1]; b = pix[p + 2];
            r += (unsigned char)((unsigned)(g2r * (signed char)g) >> 5);
            b += (unsigned char)((unsigned)(g2b * (signed char)g) >> 5);
            b += (unsigned char)((unsigned)(r2b * (signed char)r) >> 5);
            pix[p] = r;
            pix[p + 2] = b;
        }
    }
}

static unsigned char *wl_inv_index(struct wl_tf *t, unsigned char *pix, int h)
{
    int x, y, d = 0, p = 0;
    unsigned v = 0, vmask = 0, bpp = 8 >> t->bits, xmask = 0;
    unsigned char *dst;
    if (t->bits == 0) {
        for (p = 0; p < t->old_w * h * 4; p += 4) {
            int i = 4 * pix[p + 1];
            memcpy(pix + p, t->pix + i, 4);
        }
        return pix;
    }
    if (t->bits == 1) { vmask = 15; xmask = 1; }
    else if (t->bits == 2) { vmask = 3; xmask = 3; }
    else { vmask = 1; xmask = 7; }
    dst = malloc(4 * t->old_w * h);
    if (!dst) { free(pix); return 0; }
    for (y = 0; y < h; y++)
        for (x = 0; x < t->old_w; x++) {
            if (!(x & xmask)) { v = pix[p + 1]; p += 4; }
            memcpy(dst + d, t->pix + 4 * (v & vmask), 4);
            d += 4;
            v >>= bpp;
        }
    free(pix);
    return dst;
}

/* a VP8L bitstream -> RGBA bytes (malloc'd), its size in *pw, *ph */
static unsigned char *vp8l_decode(const unsigned char *b, int n, int *pw, int *ph)
{
    struct wl_dec d;
    struct wl_tf tf[4];
    int ntf = 0, seen = 0, w, h, ow, i;
    unsigned char *pix = 0;
    memset(&d, 0, sizeof d);
    d.b = b; d.n = n;
    if (wl_read(&d, 8) != 0x2f) return 0;
    w = wl_read(&d, 14) + 1;
    h = wl_read(&d, 14) + 1;
    wl_read(&d, 1);
    if (wl_read(&d, 3) != 0 || d.bad) return 0;
    ow = w;
    while (wl_read(&d, 1)) {
        struct wl_tf *t = &tf[ntf];
        if (d.bad || ntf >= 4) goto fail;
        memset(t, 0, sizeof *t);
        t->old_w = w;
        t->type = wl_read(&d, 2);
        if (seen & (1 << t->type)) goto fail;
        seen |= 1 << t->type;
        ntf++;
        if (t->type == 0 || t->type == 1) {
            t->bits = wl_read(&d, 3) + 2;
            if (!(t->pix = wl_pix(&d, wl_tiles(w, t->bits), wl_tiles(h, t->bits), 0, 0))) goto fail;
        } else if (t->type == 3) {
            int nc = wl_read(&d, 8) + 1, p;
            t->bits = nc <= 2 ? 3 : nc <= 4 ? 2 : nc <= 16 ? 1 : 0;
            w = wl_tiles(w, t->bits);
            if (!(t->pix = wl_pix(&d, nc, 1, 4 * 256, 0))) goto fail;
            memset(t->pix + 4 * nc, 0, 4 * (256 - nc));
            for (p = 4; p < 4 * nc; p++) t->pix[p] += t->pix[p - 4];
        }
    }
    if (!(pix = wl_pix(&d, w, h, 0, 1))) goto fail;
    for (i = ntf - 1; i >= 0; i--) {
        struct wl_tf *t = &tf[i];
        if (t->type == 0) wl_inv_predictor(t, pix, h);
        else if (t->type == 1) wl_inv_cross(t, pix, h);
        else if (t->type == 2) {
            int p;
            for (p = 0; p < t->old_w * h * 4; p += 4) { pix[p] += pix[p + 1]; pix[p + 2] += pix[p + 1]; }
        } else if (!(pix = wl_inv_index(t, pix, h))) goto fail;
    }
    for (i = 0; i < ntf; i++) free(tf[i].pix);
    *pw = ow;
    *ph = h;
    return pix;
fail:
    for (i = 0; i < ntf; i++) free(tf[i].pix);
    free(pix);
    return 0;
}

/* ================================================================
 * VP8 - lossy (key frames: what a WebP holds)
 * ================================================================ */
static const unsigned char v8_lut_shift[127] = {
    7, 6, 6, 5, 5, 5, 5, 4, 4, 4, 4, 4, 4, 4, 4,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
static const unsigned char v8_lut_range[127] = {
    127,
    127, 191,
    127, 159, 191, 223,
    127, 143, 159, 175, 191, 207, 223, 239,
    127, 135, 143, 151, 159, 167, 175, 183, 191, 199, 207, 215, 223, 231, 239, 247,
    127, 131, 135, 139, 143, 147, 151, 155, 159, 163, 167, 171, 175, 179, 183, 187,
    191, 195, 199, 203, 207, 211, 215, 219, 223, 227, 231, 235, 239, 243, 247, 251,
    127, 129, 131, 133, 135, 137, 139, 141, 143, 145, 147, 149, 151, 153, 155, 157,
    159, 161, 163, 165, 167, 169, 171, 173, 175, 177, 179, 181, 183, 185, 187, 189,
    191, 193, 195, 197, 199, 201, 203, 205, 207, 209, 211, 213, 215, 217, 219, 221,
    223, 225, 227, 229, 231, 233, 235, 237, 239, 241, 243, 245, 247, 249, 251, 253 };

struct v8_part { const unsigned char *buf; int n, r; unsigned range, bits; int nbits, eof; };

static void v8_part_init(struct v8_part *p, const unsigned char *b, int n)
{
    p->buf = b; p->n = n; p->r = 0; p->range = 254; p->bits = 0; p->nbits = 0; p->eof = 0;
}
static int v8_bit(struct v8_part *p, unsigned prob)
{
    unsigned split;
    int bit;
    if (p->nbits < 8) {
        if (p->r >= p->n) { p->eof = 1; return 0; }
        p->bits |= (unsigned)p->buf[p->r++] << (8 - p->nbits);
        p->nbits += 8;
    }
    split = ((p->range * prob) >> 8) + 1;
    bit = p->bits >= split << 8;
    if (bit) { p->range -= split; p->bits -= split << 8; }
    else p->range = split - 1;
    if (p->range < 127) {
        int sh = v8_lut_shift[p->range];
        p->range = v8_lut_range[p->range];
        p->bits <<= sh;
        p->nbits -= sh;
    }
    return bit;
}
static unsigned v8_uint(struct v8_part *p, unsigned prob, int n)
{
    unsigned u = 0;
    while (n > 0) { n--; if (v8_bit(p, prob)) u |= 1u << n; }
    return u;
}
static int v8_int(struct v8_part *p, unsigned prob, int n)
{
    int u = v8_uint(p, prob, n);
    return v8_bit(p, prob) ? -u : u;
}
static int v8_opt_int(struct v8_part *p, unsigned prob, int n) { return v8_bit(p, prob) ? v8_int(p, prob, n) : 0; }

enum { V8_DC, V8_TM, V8_VE, V8_HE, V8_RD, V8_VR, V8_LD, V8_VL, V8_HD, V8_HU, V8_DCTOP, V8_DCLEFT, V8_DCTOPLEFT };

static const unsigned char v8_pred_prob[10][10][9] = {
    { {231, 120, 48, 89, 115, 113, 120, 152, 112}, {152, 179, 64, 126, 170, 118, 46, 70, 95}, {175, 69, 143, 80, 85, 82, 72, 155, 103},
      {56, 58, 10, 171, 218, 189, 17, 13, 152}, {114, 26, 17, 163, 44, 195, 21, 10, 173}, {121, 24, 80, 195, 26, 62, 44, 64, 85},
      {144, 71, 10, 38, 171, 213, 144, 34, 26}, {170, 46, 55, 19, 136, 160, 33, 206, 71}, {63, 20, 8, 114, 114, 208, 12, 9, 226},
      {81, 40, 11, 96, 182, 84, 29, 16, 36} },
    { {134, 183, 89, 137, 98, 101, 106, 165, 148}, {72, 187, 100, 130, 157, 111, 32, 75, 80}, {66, 102, 167, 99, 74, 62, 40, 234, 128},
      {41, 53, 9, 178, 241, 141, 26, 8, 107}, {74, 43, 26, 146, 73, 166, 49, 23, 157}, {65, 38, 105, 160, 51, 52, 31, 115, 128},
      {104, 79, 12, 27, 217, 255, 87, 17, 7}, {87, 68, 71, 44, 114, 51, 15, 186, 23}, {47, 41, 14, 110, 182, 183, 21, 17, 194},
      {66, 45, 25, 102, 197, 189, 23, 18, 22} },
    { {88, 88, 147, 150, 42, 46, 45, 196, 205}, {43, 97, 183, 117, 85, 38, 35, 179, 61}, {39, 53, 200, 87, 26, 21, 43, 232, 171},
      {56, 34, 51, 104, 114, 102, 29, 93, 77}, {39, 28, 85, 171, 58, 165, 90, 98, 64}, {34, 22, 116, 206, 23, 34, 43, 166, 73},
      {107, 54, 32, 26, 51, 1, 81, 43, 31}, {68, 25, 106, 22, 64, 171, 36, 225, 114}, {34, 19, 21, 102, 132, 188, 16, 76, 124},
      {62, 18, 78, 95, 85, 57, 50, 48, 51} },
    { {193, 101, 35, 159, 215, 111, 89, 46, 111}, {60, 148, 31, 172, 219, 228, 21, 18, 111}, {112, 113, 77, 85, 179, 255, 38, 120, 114},
      {40, 42, 1, 196, 245, 209, 10, 25, 109}, {88, 43, 29, 140, 166, 213, 37, 43, 154}, {61, 63, 30, 155, 67, 45, 68, 1, 209},
      {100, 80, 8, 43, 154, 1, 51, 26, 71}, {142, 78, 78, 16, 255, 128, 34, 197, 171}, {41, 40, 5, 102, 211, 183, 4, 1, 221},
      {51, 50, 17, 168, 209, 192, 23, 25, 82} },
    { {138, 31, 36, 171, 27, 166, 38, 44, 229}, {67, 87, 58, 169, 82, 115, 26, 59, 179}, {63, 59, 90, 180, 59, 166, 93, 73, 154},
      {40, 40, 21, 116, 143, 209, 34, 39, 175}, {47, 15, 16, 183, 34, 223, 49, 45, 183}, {46, 17, 33, 183, 6, 98, 15, 32, 183},
      {57, 46, 22, 24, 128, 1, 54, 17, 37}, {65, 32, 73, 115, 28, 128, 23, 128, 205}, {40, 3, 9, 115, 51, 192, 18, 6, 223},
      {87, 37, 9, 115, 59, 77, 64, 21, 47} },
    { {104, 55, 44, 218, 9, 54, 53, 130, 226}, {64, 90, 70, 205, 40, 41, 23, 26, 57}, {54, 57, 112, 184, 5, 41, 38, 166, 213},
      {30, 34, 26, 133, 152, 116, 10, 32, 134}, {39, 19, 53, 221, 26, 114, 32, 73, 255}, {31, 9, 65, 234, 2, 15, 1, 118, 73},
      {75, 32, 12, 51, 192, 255, 160, 43, 51}, {88, 31, 35, 67, 102, 85, 55, 186, 85}, {56, 21, 23, 111, 59, 205, 45, 37, 192},
      {55, 38, 70, 124, 73, 102, 1, 34, 98} },
    { {125, 98, 42, 88, 104, 85, 117, 175, 82}, {95, 84, 53, 89, 128, 100, 113, 101, 45}, {75, 79, 123, 47, 51, 128, 81, 171, 1},
      {57, 17, 5, 71, 102, 57, 53, 41, 49}, {38, 33, 13, 121, 57, 73, 26, 1, 85}, {41, 10, 67, 138, 77, 110, 90, 47, 114},
      {115, 21, 2, 10, 102, 255, 166, 23, 6}, {101, 29, 16, 10, 85, 128, 101, 196, 26}, {57, 18, 10, 102, 102, 213, 34, 20, 43},
      {117, 20, 15, 36, 163, 128, 68, 1, 26} },
    { {102, 61, 71, 37, 34, 53, 31, 243, 192}, {69, 60, 71, 38, 73, 119, 28, 222, 37}, {68, 45, 128, 34, 1, 47, 11, 245, 171},
      {62, 17, 19, 70, 146, 85, 55, 62, 70}, {37, 43, 37, 154, 100, 163, 85, 160, 1}, {63, 9, 92, 136, 28, 64, 32, 201, 85},
      {75, 15, 9, 9, 64, 255, 184, 119, 16}, {86, 6, 28, 5, 64, 255, 25, 248, 1}, {56, 8, 17, 132, 137, 255, 55, 116, 128},
      {58, 15, 20, 82, 135, 57, 26, 121, 40} },
    { {164, 50, 31, 137, 154, 133, 25, 35, 218}, {51, 103, 44, 131, 131, 123, 31, 6, 158}, {86, 40, 64, 135, 148, 224, 45, 183, 128},
      {22, 26, 17, 131, 240, 154, 14, 1, 209}, {45, 16, 21, 91, 64, 222, 7, 1, 197}, {56, 21, 39, 155, 60, 138, 23, 102, 213},
      {83, 12, 13, 54, 192, 255, 68, 47, 28}, {85, 26, 85, 85, 128, 128, 32, 146, 171}, {18, 11, 7, 63, 144, 171, 4, 4, 246},
      {35, 27, 10, 146, 174, 171, 12, 26, 128} },
    { {190, 80, 35, 99, 180, 80, 126, 54, 45}, {85, 126, 47, 87, 176, 51, 41, 20, 32}, {101, 75, 128, 139, 118, 146, 116, 128, 85},
      {56, 41, 15, 176, 236, 85, 37, 9, 62}, {71, 30, 17, 119, 118, 255, 17, 18, 138}, {101, 38, 60, 138, 55, 70, 43, 26, 142},
      {146, 36, 19, 30, 171, 255, 97, 27, 20}, {138, 45, 61, 62, 219, 1, 81, 188, 64}, {32, 41, 20, 117, 151, 142, 20, 21, 163},
      {112, 19, 12, 61, 195, 128, 48, 4, 24} } };

#include "webp_tab.h"

static const unsigned short v8_dc_tab[128] = {
    4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 17, 18, 19, 20, 20, 21, 21, 22, 22, 23, 23, 24, 25, 25, 26, 27, 28,
    29, 30, 31, 32, 33, 34, 35, 36, 37, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58,
    59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89,
    91, 93, 95, 96, 98, 100, 101, 102, 104, 106, 108, 110, 112, 114, 116, 118, 122, 124, 126, 128, 130, 132, 134, 136, 138, 140, 143, 145, 148, 151, 154, 157 };
static const unsigned short v8_ac_tab[128] = {
    4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
    36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 60, 62, 64, 66, 68, 70, 72, 74, 76,
    78, 80, 82, 84, 86, 88, 90, 92, 94, 96, 98, 100, 102, 104, 106, 108, 110, 112, 114, 116, 119, 122, 125, 128, 131, 134, 137, 140,
    143, 146, 149, 152, 155, 158, 161, 164, 167, 170, 173, 177, 181, 185, 189, 193, 197, 201, 205, 209, 213, 217, 221, 225, 229, 234,
    239, 245, 249, 254, 259, 264, 269, 274, 279, 284 };

static const unsigned char v8_bands[17] = { 0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0 };
static const unsigned char v8_cat3456[4][12] = {
    {173, 148, 140, 0, 0, 0, 0, 0, 0, 0, 0, 0}, {176, 155, 140, 135, 0, 0, 0, 0, 0, 0, 0, 0},
    {180, 157, 141, 134, 130, 0, 0, 0, 0, 0, 0, 0}, {254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129, 0} };
static const unsigned char v8_zigzag[16] = { 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };

struct v8_mb { unsigned char pred[4], nzmask, nzy16; };
struct v8_fp { unsigned char level, ilevel, hlevel, inner; };

struct v8 {
    int w, h, mbw, mbh, ystride, cstride;
    unsigned char *Y, *U, *V;
    struct v8_part fp, op[8];
    int nop;
    int use_seg, update_map, rel_delta;
    signed char seg_q[4], seg_f[4];
    unsigned char seg_prob[3];
    int f_simple, f_level, f_sharp, use_lf_delta;
    signed char ref_lf[4], mode_lf[4];
    unsigned short q[4][3][2];                            /* y1, y2, uv: dc, ac */
    unsigned char prob[4][8][3][11];
    int use_skip; unsigned skip_prob;
    struct v8_fp fparams[4][2], *mbf;
    int segment;
    struct v8_mb left, *up;
    unsigned nzdc, nzac;
    int y16;
    unsigned char pred_y16, pred_c8, pred_y4[4][4];
    short coeff[16 * 16 + 2 * 8 * 8 + 4 * 4];
    unsigned char ybr[26][32];
};

static int v8_clip(int x, int lo, int hi) { return x < lo ? lo : x > hi ? hi : x; }
static unsigned char v8_clip8(int i) { return i < 0 ? 0 : i > 255 ? 255 : i; }

static void v8_inv_dct4(struct v8 *z, int y, int x, int cb)
{
    const int c1 = 85627, c2 = 35468;
    int m[4][4], i, j;
    for (i = 0; i < 4; i++, cb++) {
        int a = z->coeff[cb] + z->coeff[cb + 8], b = z->coeff[cb] - z->coeff[cb + 8];
        int c = ((z->coeff[cb + 4] * c2) >> 16) - ((z->coeff[cb + 12] * c1) >> 16);
        int d = ((z->coeff[cb + 4] * c1) >> 16) + ((z->coeff[cb + 12] * c2) >> 16);
        m[i][0] = a + d; m[i][1] = b + c; m[i][2] = b - c; m[i][3] = a - d;
    }
    for (j = 0; j < 4; j++) {
        int dc = m[0][j] + 4, a = dc + m[2][j], b = dc - m[2][j];
        int c = ((m[1][j] * c2) >> 16) - ((m[3][j] * c1) >> 16);
        int d = ((m[1][j] * c1) >> 16) + ((m[3][j] * c2) >> 16);
        z->ybr[y + j][x + 0] = v8_clip8(z->ybr[y + j][x + 0] + ((a + d) >> 3));
        z->ybr[y + j][x + 1] = v8_clip8(z->ybr[y + j][x + 1] + ((b + c) >> 3));
        z->ybr[y + j][x + 2] = v8_clip8(z->ybr[y + j][x + 2] + ((b - c) >> 3));
        z->ybr[y + j][x + 3] = v8_clip8(z->ybr[y + j][x + 3] + ((a - d) >> 3));
    }
}
static void v8_inv_dct4_dc(struct v8 *z, int y, int x, int cb)
{
    int dc = (z->coeff[cb] + 4) >> 3, i, j;
    for (j = 0; j < 4; j++) for (i = 0; i < 4; i++) z->ybr[y + j][x + i] = v8_clip8(z->ybr[y + j][x + i] + dc);
}
static void v8_inv_dct8(struct v8 *z, int y, int x, int cb, int dc_only)
{
    int k;
    for (k = 0; k < 4; k++) {
        int yy = y + (k >> 1) * 4, xx = x + (k & 1) * 4;
        if (dc_only) v8_inv_dct4_dc(z, yy, xx, cb + 16 * k); else v8_inv_dct4(z, yy, xx, cb + 16 * k);
    }
}
static void v8_inv_wht(struct v8 *d)
{
    int m[16], i, out = 0;
    for (i = 0; i < 4; i++) {
        int a0 = d->coeff[384 + i] + d->coeff[384 + 12 + i], a1 = d->coeff[384 + 4 + i] + d->coeff[384 + 8 + i];
        int a2 = d->coeff[384 + 4 + i] - d->coeff[384 + 8 + i], a3 = d->coeff[384 + i] - d->coeff[384 + 12 + i];
        m[i] = a0 + a1; m[8 + i] = a0 - a1; m[4 + i] = a3 + a2; m[12 + i] = a3 - a2;
    }
    for (i = 0; i < 4; i++, out += 64) {
        int dc = m[i * 4] + 3, a0 = dc + m[3 + i * 4], a1 = m[1 + i * 4] + m[2 + i * 4];
        int a2 = m[1 + i * 4] - m[2 + i * 4], a3 = dc - m[3 + i * 4];
        d->coeff[out + 0] = (a0 + a1) >> 3;
        d->coeff[out + 16] = (a3 + a2) >> 3;
        d->coeff[out + 32] = (a0 - a1) >> 3;
        d->coeff[out + 48] = (a3 - a2) >> 3;
    }
}

/* ---- prediction ---- */
#define YB(j, i) z->ybr[y + (j)][x + (i)]
static void v8_fill(struct v8 *z, int y, int x, int n, unsigned char v)
{
    int i, j;
    for (j = 0; j < n; j++) for (i = 0; i < n; i++) YB(j, i) = v;
}
static void v8_pred_dc(struct v8 *z, int y, int x, int n, int top, int left)
{
    unsigned sum = 0, cnt = 0;
    int i;
    if (top) { for (i = 0; i < n; i++) sum += YB(-1, i); cnt += n; }
    if (left) { for (i = 0; i < n; i++) sum += YB(i, -1); cnt += n; }
    v8_fill(z, y, x, n, cnt ? (sum + cnt / 2) / cnt : 0x80);
}
static void v8_pred_tm(struct v8 *z, int y, int x, int n)
{
    int d0 = -YB(-1, -1), i, j;
    for (j = 0; j < n; j++) {
        int d1 = d0 + YB(j, -1);
        for (i = 0; i < n; i++) YB(j, i) = v8_clip(d1 + YB(-1, i), 0, 255);
    }
}
static void v8_pred_ve(struct v8 *z, int y, int x, int n)
{
    int i, j;
    for (j = 0; j < n; j++) for (i = 0; i < n; i++) YB(j, i) = YB(-1, i);
}
static void v8_pred_he(struct v8 *z, int y, int x, int n)
{
    int i, j;
    for (j = 0; j < n; j++) for (i = 0; i < n; i++) YB(j, i) = YB(j, -1);
}
/* 16x16 and the chroma's 8x8 */
static void v8_pred_big(struct v8 *z, int y, int x, int n, int mode)
{
    switch (mode) {
    case V8_DC: v8_pred_dc(z, y, x, n, 1, 1); break;
    case V8_TM: v8_pred_tm(z, y, x, n); break;
    case V8_VE: v8_pred_ve(z, y, x, n); break;
    case V8_HE: v8_pred_he(z, y, x, n); break;
    case V8_DCTOP: v8_pred_dc(z, y, x, n, 0, 1); break;
    case V8_DCLEFT: v8_pred_dc(z, y, x, n, 1, 0); break;
    default: v8_fill(z, y, x, n, 0x80); break;
    }
}
#define AV3(a, b, c) (unsigned char)(((a) + 2 * (b) + (c) + 2) / 4)
#define AV2(a, b) (unsigned char)(((a) + (b) + 1) / 2)
static void v8_pred4(struct v8 *z, int y, int x, int mode)
{
    int s = YB(3, -1), r = YB(2, -1), q = YB(1, -1), p = YB(0, -1), a = YB(-1, -1);
    int b = YB(-1, 0), c = YB(-1, 1), d = YB(-1, 2), e = YB(-1, 3), f = YB(-1, 4), g = YB(-1, 5), h = YB(-1, 6), hh = YB(-1, 7);
    int i, j;
    switch (mode) {
    case V8_DC: {
        unsigned sum = 4;
        for (i = 0; i < 4; i++) sum += YB(-1, i) + YB(i, -1);
        v8_fill(z, y, x, 4, sum / 8);
        break;
    }
    case V8_TM: v8_pred_tm(z, y, x, 4); break;
    case V8_VE: {
        unsigned char v0 = AV3(a, b, c), v1 = AV3(b, c, d), v2 = AV3(c, d, e), v3 = AV3(d, e, f);
        for (j = 0; j < 4; j++) { YB(j, 0) = v0; YB(j, 1) = v1; YB(j, 2) = v2; YB(j, 3) = v3; }
        break;
    }
    case V8_HE: {
        unsigned char ssr = AV3(s, s, r), srq = AV3(s, r, q), rqp = AV3(r, q, p), apq = AV3(a, p, q);
        for (i = 0; i < 4; i++) { YB(0, i) = apq; YB(1, i) = rqp; YB(2, i) = srq; YB(3, i) = ssr; }
        break;
    }
    case V8_RD: {
        unsigned char srq = AV3(s, r, q), rqp = AV3(r, q, p), qpa = AV3(q, p, a), pab = AV3(p, a, b);
        unsigned char abc = AV3(a, b, c), bcd = AV3(b, c, d), cde = AV3(c, d, e);
        YB(0, 0) = pab; YB(0, 1) = abc; YB(0, 2) = bcd; YB(0, 3) = cde;
        YB(1, 0) = qpa; YB(1, 1) = pab; YB(1, 2) = abc; YB(1, 3) = bcd;
        YB(2, 0) = rqp; YB(2, 1) = qpa; YB(2, 2) = pab; YB(2, 3) = abc;
        YB(3, 0) = srq; YB(3, 1) = rqp; YB(3, 2) = qpa; YB(3, 3) = pab;
        break;
    }
    case V8_VR: {
        unsigned char ab = AV2(a, b), bc = AV2(b, c), cd = AV2(c, d), de = AV2(d, e);
        unsigned char rqp = AV3(r, q, p), qpa = AV3(q, p, a), pab = AV3(p, a, b), abc = AV3(a, b, c), bcd = AV3(b, c, d), cde = AV3(c, d, e);
        YB(0, 0) = ab; YB(0, 1) = bc; YB(0, 2) = cd; YB(0, 3) = de;
        YB(1, 0) = pab; YB(1, 1) = abc; YB(1, 2) = bcd; YB(1, 3) = cde;
        YB(2, 0) = qpa; YB(2, 1) = ab; YB(2, 2) = bc; YB(2, 3) = cd;
        YB(3, 0) = rqp; YB(3, 1) = pab; YB(3, 2) = abc; YB(3, 3) = bcd;
        break;
    }
    case V8_LD: {                                        /* (b..hh: the eight above) */
        unsigned char abc = AV3(b, c, d), bcd = AV3(c, d, e), cde = AV3(d, e, f), def = AV3(e, f, g);
        unsigned char efg = AV3(f, g, h), fgh = AV3(g, h, hh), ghh = AV3(h, hh, hh);
        YB(0, 0) = abc; YB(0, 1) = bcd; YB(0, 2) = cde; YB(0, 3) = def;
        YB(1, 0) = bcd; YB(1, 1) = cde; YB(1, 2) = def; YB(1, 3) = efg;
        YB(2, 0) = cde; YB(2, 1) = def; YB(2, 2) = efg; YB(2, 3) = fgh;
        YB(3, 0) = def; YB(3, 1) = efg; YB(3, 2) = fgh; YB(3, 3) = ghh;
        break;
    }
    case V8_VL: {
        unsigned char ab = AV2(b, c), bc = AV2(c, d), cd = AV2(d, e), de = AV2(e, f);
        unsigned char abc = AV3(b, c, d), bcd = AV3(c, d, e), cde = AV3(d, e, f), def = AV3(e, f, g), efg = AV3(f, g, h), fgh = AV3(g, h, hh);
        YB(0, 0) = ab; YB(0, 1) = bc; YB(0, 2) = cd; YB(0, 3) = de;
        YB(1, 0) = abc; YB(1, 1) = bcd; YB(1, 2) = cde; YB(1, 3) = def;
        YB(2, 0) = bc; YB(2, 1) = cd; YB(2, 2) = de; YB(2, 3) = efg;
        YB(3, 0) = bcd; YB(3, 1) = cde; YB(3, 2) = def; YB(3, 3) = fgh;
        break;
    }
    case V8_HD: {
        unsigned char sr = AV2(s, r), rq = AV2(r, q), qp = AV2(q, p), pa = AV2(p, a);
        unsigned char srq = AV3(s, r, q), rqp = AV3(r, q, p), qpa = AV3(q, p, a), pab = AV3(p, a, b), abc = AV3(a, b, c), bcd = AV3(b, c, d);
        YB(0, 0) = pa; YB(0, 1) = pab; YB(0, 2) = abc; YB(0, 3) = bcd;
        YB(1, 0) = qp; YB(1, 1) = qpa; YB(1, 2) = pa; YB(1, 3) = pab;
        YB(2, 0) = rq; YB(2, 1) = rqp; YB(2, 2) = qp; YB(2, 3) = qpa;
        YB(3, 0) = sr; YB(3, 1) = srq; YB(3, 2) = rq; YB(3, 3) = rqp;
        break;
    }
    default: {                                           /* HU */
        unsigned char pq = AV2(p, q), qr = AV2(q, r), rs = AV2(r, s), pqr = AV3(p, q, r), qrs = AV3(q, r, s), rss = AV3(r, s, s), sss = s;
        YB(0, 0) = pq; YB(0, 1) = pqr; YB(0, 2) = qr; YB(0, 3) = qrs;
        YB(1, 0) = qr; YB(1, 1) = qrs; YB(1, 2) = rs; YB(1, 3) = rss;
        YB(2, 0) = rs; YB(2, 1) = rss; YB(2, 2) = sss; YB(2, 3) = sss;
        YB(3, 0) = sss; YB(3, 1) = sss; YB(3, 2) = sss; YB(3, 3) = sss;
        break;
    }
    }
}
#undef YB

static int v8_top_left(int mbx, int mby, int p)
{
    if (p != V8_DC) return p;
    if (mbx == 0) return mby == 0 ? V8_DCTOPLEFT : V8_DCLEFT;
    return mby == 0 ? V8_DCTOP : V8_DC;
}

/* ---- the frame's headers ---- */
static void v8_filter_params(struct v8 *d)
{
    int i, j;
    for (i = 0; i < 4; i++) {
        int base = d->f_level;
        if (d->use_seg) { base = d->seg_f[i]; if (d->rel_delta) base += d->f_level; }
        for (j = 0; j < 2; j++) {
            struct v8_fp *p = &d->fparams[i][j];
            int level = base, il;
            p->inner = j != 0;
            if (d->use_lf_delta) { level += d->ref_lf[0]; if (j) level += d->mode_lf[0]; }
            if (level <= 0) { p->level = 0; continue; }
            if (level > 63) level = 63;
            il = level;
            if (d->f_sharp > 0) {
                il >>= d->f_sharp > 4 ? 2 : 1;
                if (il > 9 - d->f_sharp) il = 9 - d->f_sharp;
            }
            if (il < 1) il = 1;
            p->ilevel = il;
            p->level = 2 * level + il;
            p->hlevel = level < 15 ? 0 : level < 40 ? 1 : 2;
        }
    }
}

static int v8_headers(struct v8 *d, const unsigned char *b, int n, int first_len)
{
    struct v8_part *fp = &d->fp;
    int i, j, k, l, last, plen[8], base;
    if (first_len > n) return 0;
    v8_part_init(fp, b, first_len);
    b += first_len; n -= first_len;
    v8_bit(fp, 128); v8_bit(fp, 128);                    /* color space, clamping */
    d->use_seg = v8_bit(fp, 128);                         /* segments */
    if (d->use_seg) {
        d->update_map = v8_bit(fp, 128);
        if (v8_bit(fp, 128)) {
            d->rel_delta = !v8_bit(fp, 128);
            for (i = 0; i < 4; i++) d->seg_q[i] = v8_opt_int(fp, 128, 7);
            for (i = 0; i < 4; i++) d->seg_f[i] = v8_opt_int(fp, 128, 6);
        }
        if (d->update_map) for (i = 0; i < 3; i++) d->seg_prob[i] = v8_bit(fp, 128) ? v8_uint(fp, 128, 8) : 255;
    }
    d->f_simple = v8_bit(fp, 128);                       /* the loop filter */
    d->f_level = v8_uint(fp, 128, 6);
    d->f_sharp = v8_uint(fp, 128, 3);
    d->use_lf_delta = v8_bit(fp, 128);
    if (d->use_lf_delta && v8_bit(fp, 128)) {
        for (i = 0; i < 4; i++) d->ref_lf[i] = v8_opt_int(fp, 128, 6);
        for (i = 0; i < 4; i++) d->mode_lf[i] = v8_opt_int(fp, 128, 6);
    }
    if (d->f_level) v8_filter_params(d);
    d->nop = 1 << v8_uint(fp, 128, 2);                   /* the token partitions */
    k = 3 * (d->nop - 1);
    if (k > n) return 0;
    last = n - k;
    for (i = 0; i < d->nop - 1; i++) {
        plen[i] = b[3 * i] | b[3 * i + 1] << 8 | b[3 * i + 2] << 16;
        if (plen[i] > last) return 0;
        last -= plen[i];
    }
    plen[d->nop - 1] = last;
    b += k;
    for (i = 0; i < d->nop; i++) { v8_part_init(&d->op[i], b, plen[i]); b += plen[i]; }
    base = v8_uint(fp, 128, 7);                          /* quantizers */
    {
        int y1dc = v8_opt_int(fp, 128, 4), y2dc = v8_opt_int(fp, 128, 4), y2ac = v8_opt_int(fp, 128, 4);
        int uvdc = v8_opt_int(fp, 128, 4), uvac = v8_opt_int(fp, 128, 4);
        for (i = 0; i < 4; i++) {
            int q = base;
            if (d->use_seg) q = d->rel_delta ? q + d->seg_q[i] : d->seg_q[i];
            d->q[i][0][0] = v8_dc_tab[v8_clip(q + y1dc, 0, 127)];
            d->q[i][0][1] = v8_ac_tab[v8_clip(q, 0, 127)];
            d->q[i][1][0] = v8_dc_tab[v8_clip(q + y2dc, 0, 127)] * 2;
            d->q[i][1][1] = v8_ac_tab[v8_clip(q + y2ac, 0, 127)] * 155 / 100;
            if (d->q[i][1][1] < 8) d->q[i][1][1] = 8;
            d->q[i][2][0] = v8_dc_tab[v8_clip(q + uvdc, 0, 117)];
            d->q[i][2][1] = v8_ac_tab[v8_clip(q + uvac, 0, 127)];
        }
    }
    v8_bit(fp, 128);                                     /* refresh entropy probs */
    memcpy(d->prob, v8_default_prob, sizeof d->prob);
    for (i = 0; i < 4; i++) for (j = 0; j < 8; j++) for (k = 0; k < 3; k++) for (l = 0; l < 11; l++)
        if (v8_bit(fp, v8_update_prob[i][j][k][l])) d->prob[i][j][k][l] = v8_uint(fp, 128, 8);
    d->use_skip = v8_bit(fp, 128);
    if (d->use_skip) d->skip_prob = v8_uint(fp, 128, 8);
    return !fp->eof;
}

/* ---- a macroblock ---- */
static void v8_prepare(struct v8 *d, int mbx, int mby)
{
    int x, y, i;
    if (mbx == 0) {
        for (y = 0; y < 17; y++) d->ybr[y][7] = 0x81;
        for (y = 17; y < 26; y++) { d->ybr[y][7] = 0x81; d->ybr[y][23] = 0x81; }
    } else {
        for (y = 0; y < 17; y++) d->ybr[y][7] = d->ybr[y][23];
        for (y = 17; y < 26; y++) { d->ybr[y][7] = d->ybr[y][15]; d->ybr[y][23] = d->ybr[y][31]; }
    }
    if (mby == 0) {
        for (x = 7; x < 28; x++) d->ybr[0][x] = 0x7f;
        for (x = 7; x < 16; x++) d->ybr[17][x] = 0x7f;
        for (x = 23; x < 32; x++) d->ybr[17][x] = 0x7f;
    } else {
        for (i = 0; i < 16; i++) d->ybr[0][8 + i] = d->Y[(16 * mby - 1) * d->ystride + 16 * mbx + i];
        for (i = 0; i < 8; i++) d->ybr[17][8 + i] = d->U[(8 * mby - 1) * d->cstride + 8 * mbx + i];
        for (i = 0; i < 8; i++) d->ybr[17][24 + i] = d->V[(8 * mby - 1) * d->cstride + 8 * mbx + i];
        for (i = 16; i < 20; i++)
            d->ybr[0][8 + i] = d->Y[(16 * mby - 1) * d->ystride + 16 * mbx + (mbx == d->mbw - 1 ? 15 : i)];
    }
    for (y = 4; y < 16; y += 4) for (i = 24; i < 28; i++) d->ybr[y][i] = d->ybr[0][i];
}

static unsigned v8_pack(const unsigned char *x, int shift)
{
    return (unsigned)(x[0] | x[1] << 1 | x[2] << 2 | x[3] << 3) << shift;
}
static void v8_unpack(unsigned v, unsigned char *x) { x[0] = v & 1; x[1] = v >> 1 & 1; x[2] = v >> 2 & 1; x[3] = v >> 3 & 1; }

static int v8_res4(struct v8 *d, struct v8_part *r, int plane, int ctx, const unsigned short *quant, int skip_first, int cb)
{
    const unsigned char (*prob)[3][11] = d->prob[plane];
    const unsigned char *p;
    int n = skip_first ? 1 : 0;
    p = prob[v8_bands[n]][ctx];
    if (!v8_bit(r, p[0])) return 0;
    while (n != 16) {
        unsigned v;
        int z, c;
        n++;
        if (!v8_bit(r, p[1])) { p = prob[v8_bands[n]][0]; continue; }
        if (!v8_bit(r, p[2])) { v = 1; p = prob[v8_bands[n]][1]; }
        else {
            if (!v8_bit(r, p[3])) {
                if (!v8_bit(r, p[4])) v = 2;
                else v = 3 + v8_uint(r, p[5], 1);
            } else if (!v8_bit(r, p[6])) {
                if (!v8_bit(r, p[7])) v = 5 + v8_uint(r, 159, 1);
                else { v = 7 + 2 * v8_uint(r, 165, 1); v += v8_uint(r, 145, 1); }
            } else {
                unsigned b1 = v8_uint(r, p[8], 1), b0 = v8_uint(r, p[9 + b1], 1), cat = 2 * b1 + b0;
                const unsigned char *tab = v8_cat3456[cat];
                int i;
                v = 0;
                for (i = 0; tab[i]; i++) v = v * 2 + v8_uint(r, tab[i], 1);
                v += 3 + (8 << cat);
            }
            p = prob[v8_bands[n]][2];
        }
        z = v8_zigzag[n - 1];
        c = (int)v * quant[z > 0];
        if (v8_bit(r, 128)) c = -c;
        d->coeff[cb + z] = c;
        if (n == 16 || !v8_bit(r, p[0])) return 1;
    }
    return 1;
}

static int v8_residuals(struct v8 *d, int mbx, int mby)
{
    struct v8_part *part = &d->op[mby & (d->nop - 1)];
    int plane = 3, x, y, c, cb = 0;
    unsigned short (*q)[2] = d->q[d->segment];
    unsigned char nzdc[4], nzac[4], lnz[4], unz[4];
    unsigned dcm = 0, acm = 0, lm, um;
    if (d->y16) {
        int nz = v8_res4(d, part, 1, d->left.nzy16 + d->up[mbx].nzy16, q[1], 0, 384);
        d->left.nzy16 = nz;
        d->up[mbx].nzy16 = nz;
        v8_inv_wht(d);
        plane = 0;
    }
    v8_unpack(d->left.nzmask & 15, lnz);
    v8_unpack(d->up[mbx].nzmask & 15, unz);
    for (y = 0; y < 4; y++) {
        int nz = lnz[y];
        for (x = 0; x < 4; x++) {
            nz = v8_res4(d, part, plane, nz + unz[x], q[0], d->y16, cb);
            unz[x] = nz;
            nzac[x] = nz;
            nzdc[x] = d->coeff[cb] != 0;
            cb += 16;
        }
        lnz[y] = nz;
        dcm |= v8_pack(nzdc, y * 4);
        acm |= v8_pack(nzac, y * 4);
    }
    lm = v8_pack(lnz, 0);
    um = v8_pack(unz, 0);
    v8_unpack(d->left.nzmask >> 4, lnz);
    v8_unpack(d->up[mbx].nzmask >> 4, unz);
    for (c = 0; c < 4; c += 2) {
        for (y = 0; y < 2; y++) {
            int nz = lnz[y + c];
            for (x = 0; x < 2; x++) {
                nz = v8_res4(d, part, 2, nz + unz[x + c], q[2], 0, cb);
                unz[x + c] = nz;
                nzac[y * 2 + x] = nz;
                nzdc[y * 2 + x] = d->coeff[cb] != 0;
                cb += 16;
            }
            lnz[y + c] = nz;
        }
        dcm |= v8_pack(nzdc, 16 + c * 2);
        acm |= v8_pack(nzac, 16 + c * 2);
    }
    lm |= v8_pack(lnz, 4);
    um |= v8_pack(unz, 4);
    d->left.nzmask = lm;
    d->up[mbx].nzmask = um;
    d->nzdc = dcm;
    d->nzac = acm;
    return !dcm && !acm;
}

static int v8_mb(struct v8 *d, int mbx, int mby)
{
    struct v8_part *fp = &d->fp;
    int skip = 0, i, j, y, p;
    if (d->update_map) {
        if (!v8_bit(fp, d->seg_prob[0])) d->segment = v8_uint(fp, d->seg_prob[1], 1);
        else d->segment = v8_uint(fp, d->seg_prob[2], 1) + 2;
    }
    if (d->use_skip) skip = v8_bit(fp, d->skip_prob);
    memset(d->coeff, 0, sizeof d->coeff);
    v8_prepare(d, mbx, mby);
    d->y16 = v8_bit(fp, 145);
    if (d->y16) {                                        /* the 16x16 mode */
        if (!v8_bit(fp, 156)) p = v8_bit(fp, 163) ? V8_VE : V8_DC;
        else p = v8_bit(fp, 128) ? V8_TM : V8_HE;
        for (i = 0; i < 4; i++) { d->up[mbx].pred[i] = p; d->left.pred[i] = p; }
        d->pred_y16 = p;
    } else {                                             /* 16 of 4x4 */
        for (j = 0; j < 4; j++) {
            p = d->left.pred[j];
            for (i = 0; i < 4; i++) {
                const unsigned char *pr = v8_pred_prob[d->up[mbx].pred[i]][p];
                if (!v8_bit(fp, pr[0])) p = V8_DC;
                else if (!v8_bit(fp, pr[1])) p = V8_TM;
                else if (!v8_bit(fp, pr[2])) p = V8_VE;
                else if (!v8_bit(fp, pr[3])) {
                    if (!v8_bit(fp, pr[4])) p = V8_HE;
                    else if (!v8_bit(fp, pr[5])) p = V8_RD;
                    else p = V8_VR;
                } else if (!v8_bit(fp, pr[6])) p = V8_LD;
                else if (!v8_bit(fp, pr[7])) p = V8_VL;
                else if (!v8_bit(fp, pr[8])) p = V8_HD;
                else p = V8_HU;
                d->pred_y4[j][i] = p;
                d->up[mbx].pred[i] = p;
            }
            d->left.pred[j] = p;
        }
    }
    if (!v8_bit(fp, 142)) d->pred_c8 = V8_DC;            /* the chroma's */
    else if (!v8_bit(fp, 114)) d->pred_c8 = V8_VE;
    else if (!v8_bit(fp, 183)) d->pred_c8 = V8_HE;
    else d->pred_c8 = V8_TM;
    if (!skip) skip = v8_residuals(d, mbx, mby);
    else {
        if (d->y16) { d->left.nzy16 = 0; d->up[mbx].nzy16 = 0; }
        d->left.nzmask = 0;
        d->up[mbx].nzmask = 0;
        d->nzdc = d->nzac = 0;
    }
    if (d->y16) v8_pred_big(d, 1, 8, 16, v8_top_left(mbx, mby, d->pred_y16));
    for (j = 0; j < 4; j++)
        for (i = 0; i < 4; i++) {
            int n = 4 * j + i, yy = 4 * j + 1, xx = 4 * i + 8;
            unsigned m = 1u << n;
            if (!d->y16) v8_pred4(d, yy, xx, d->pred_y4[j][i]);
            if (d->nzac & m) v8_inv_dct4(d, yy, xx, 16 * n);
            else if (d->nzdc & m) v8_inv_dct4_dc(d, yy, xx, 16 * n);
        }
    p = v8_top_left(mbx, mby, d->pred_c8);
    v8_pred_big(d, 18, 8, 8, p);
    if (d->nzac & 0x0f0000) v8_inv_dct8(d, 18, 8, 256, 0);
    else if (d->nzdc & 0x0f0000) v8_inv_dct8(d, 18, 8, 256, 1);
    v8_pred_big(d, 18, 24, 8, p);
    if (d->nzac & 0xf00000) v8_inv_dct8(d, 18, 24, 320, 0);
    else if (d->nzdc & 0xf00000) v8_inv_dct8(d, 18, 24, 320, 1);
    for (y = 0; y < 16; y++) memcpy(d->Y + (mby * 16 + y) * d->ystride + mbx * 16, &d->ybr[1 + y][8], 16);
    for (y = 0; y < 8; y++) {
        memcpy(d->U + (mby * 8 + y) * d->cstride + mbx * 8, &d->ybr[18 + y][8], 8);
        memcpy(d->V + (mby * 8 + y) * d->cstride + mbx * 8, &d->ybr[18 + y][24], 8);
    }
    return skip;
}

/* ---- the loop filter ---- */
static int v8_abs(int x) { return x < 0 ? -x : x; }
static int v8_c15(int x) { return x < -16 ? -16 : x > 15 ? 15 : x; }
static int v8_c127(int x) { return x < -128 ? -128 : x > 127 ? 127 : x; }
static void v8_filter2(unsigned char *pix, int level, int index, int istep, int jstep)
{
    int n;
    for (n = 16; n > 0; n--, index += istep) {
        int p1 = pix[index - 2 * jstep], p0 = pix[index - jstep], q0 = pix[index], q1 = pix[index + jstep], a, a1, a2;
        if ((v8_abs(p0 - q0) << 1) + (v8_abs(p1 - q1) >> 1) > level) continue;
        a = 3 * (q0 - p0) + v8_c127(p1 - q1);
        a1 = v8_c15((a + 4) >> 3);
        a2 = v8_c15((a + 3) >> 3);
        pix[index - jstep] = v8_clip8(p0 + a2);
        pix[index] = v8_clip8(q0 - a1);
    }
}
static void v8_filter246(unsigned char *pix, int n, int level, int il, int hl, int index, int istep, int jstep, int four)
{
    for (; n > 0; n--, index += istep) {
        int p3 = pix[index - 4 * jstep], p2 = pix[index - 3 * jstep], p1 = pix[index - 2 * jstep], p0 = pix[index - jstep];
        int q0 = pix[index], q1 = pix[index + jstep], q2 = pix[index + 2 * jstep], q3 = pix[index + 3 * jstep];
        if ((v8_abs(p0 - q0) << 1) + (v8_abs(p1 - q1) >> 1) > level) continue;
        if (v8_abs(p3 - p2) > il || v8_abs(p2 - p1) > il || v8_abs(p1 - p0) > il ||
            v8_abs(q1 - q0) > il || v8_abs(q2 - q1) > il || v8_abs(q3 - q2) > il) continue;
        if (v8_abs(p1 - p0) > hl || v8_abs(q1 - q0) > hl) {
            int a = 3 * (q0 - p0) + v8_c127(p1 - q1), a1 = v8_c15((a + 4) >> 3), a2 = v8_c15((a + 3) >> 3);
            pix[index - jstep] = v8_clip8(p0 + a2);
            pix[index] = v8_clip8(q0 - a1);
        } else if (four) {
            int a = 3 * (q0 - p0), a1 = v8_c15((a + 4) >> 3), a2 = v8_c15((a + 3) >> 3), a3 = (a1 + 1) >> 1;
            pix[index - 2 * jstep] = v8_clip8(p1 + a3);
            pix[index - jstep] = v8_clip8(p0 + a2);
            pix[index] = v8_clip8(q0 - a1);
            pix[index + jstep] = v8_clip8(q1 - a3);
        } else {
            int a = v8_c127(3 * (q0 - p0) + v8_c127(p1 - q1));
            int a1 = (27 * a + 63) >> 7, a2 = (18 * a + 63) >> 7, a3 = (9 * a + 63) >> 7;
            pix[index - 3 * jstep] = v8_clip8(p2 + a3);
            pix[index - 2 * jstep] = v8_clip8(p1 + a2);
            pix[index - jstep] = v8_clip8(p0 + a1);
            pix[index] = v8_clip8(q0 - a1);
            pix[index + jstep] = v8_clip8(q1 - a2);
            pix[index + 2 * jstep] = v8_clip8(q2 - a3);
        }
    }
}
static void v8_loop_filter(struct v8 *d)
{
    int mbx, mby, k;
    int ys = d->ystride, cs = d->cstride;
    for (mby = 0; mby < d->mbh; mby++)
        for (mbx = 0; mbx < d->mbw; mbx++) {
            struct v8_fp f = d->mbf[d->mbw * mby + mbx];
            int l = f.level, il = f.ilevel, hl = f.hlevel, yi = (mby * ys + mbx) * 16, ci = (mby * cs + mbx) * 8;
            if (!l) continue;
            if (d->f_simple) {
                if (mbx > 0) v8_filter2(d->Y, l + 4, yi, ys, 1);
                if (f.inner) for (k = 4; k < 16; k += 4) v8_filter2(d->Y, l, yi + k, ys, 1);
                if (mby > 0) v8_filter2(d->Y, l + 4, yi, 1, ys);
                if (f.inner) for (k = 4; k < 16; k += 4) v8_filter2(d->Y, l, yi + ys * k, 1, ys);
                continue;
            }
            if (mbx > 0) {
                v8_filter246(d->Y, 16, l + 4, il, hl, yi, ys, 1, 0);
                v8_filter246(d->U, 8, l + 4, il, hl, ci, cs, 1, 0);
                v8_filter246(d->V, 8, l + 4, il, hl, ci, cs, 1, 0);
            }
            if (f.inner) {
                for (k = 4; k < 16; k += 4) v8_filter246(d->Y, 16, l, il, hl, yi + k, ys, 1, 1);
                v8_filter246(d->U, 8, l, il, hl, ci + 4, cs, 1, 1);
                v8_filter246(d->V, 8, l, il, hl, ci + 4, cs, 1, 1);
            }
            if (mby > 0) {
                v8_filter246(d->Y, 16, l + 4, il, hl, yi, 1, ys, 0);
                v8_filter246(d->U, 8, l + 4, il, hl, ci, 1, cs, 0);
                v8_filter246(d->V, 8, l + 4, il, hl, ci, 1, cs, 0);
            }
            if (f.inner) {
                for (k = 4; k < 16; k += 4) v8_filter246(d->Y, 16, l, il, hl, yi + ys * k, 1, ys, 1);
                v8_filter246(d->U, 8, l, il, hl, ci + cs * 4, 1, cs, 1);
                v8_filter246(d->V, 8, l, il, hl, ci + cs * 4, 1, cs, 1);
            }
        }
}

/* a VP8 key frame -> RGBA bytes (alpha 255), its size in *pw, *ph */
static unsigned char *vp8_decode(const unsigned char *b, int n, int *pw, int *ph)
{
    struct v8 *d;
    int first_len, mbx, mby, x, y;
    unsigned char *out = 0;
    if (n < 10 || (b[0] & 1)) return 0;                  /* (a key frame only) */
    first_len = b[0] >> 5 | b[1] << 3 | b[2] << 11;
    if (b[3] != 0x9d || b[4] != 0x01 || b[5] != 0x2a) return 0;
    d = malloc(sizeof *d);
    if (!d) return 0;
    memset(d, 0, sizeof *d);
    d->w = (b[7] & 0x3f) << 8 | b[6];
    d->h = (b[9] & 0x3f) << 8 | b[8];
    if (!d->w || !d->h) { free(d); return 0; }
    d->mbw = (d->w + 15) >> 4;
    d->mbh = (d->h + 15) >> 4;
    d->ystride = 16 * d->mbw;
    d->cstride = 8 * d->mbw;
    d->seg_prob[0] = d->seg_prob[1] = d->seg_prob[2] = 255;
    d->Y = malloc(d->ystride * 16 * d->mbh);
    d->U = malloc(d->cstride * 8 * d->mbh);
    d->V = malloc(d->cstride * 8 * d->mbh);
    d->up = malloc(d->mbw * sizeof *d->up);
    d->mbf = malloc(d->mbw * d->mbh * sizeof *d->mbf);
    if (!d->Y || !d->U || !d->V || !d->up || !d->mbf || !v8_headers(d, b + 10, n - 10, first_len)) goto done;
    memset(d->up, 0, d->mbw * sizeof *d->up);
    for (mby = 0; mby < d->mbh; mby++) {
        memset(&d->left, 0, sizeof d->left);
        for (mbx = 0; mbx < d->mbw; mbx++) {
            int skip = v8_mb(d, mbx, mby);
            struct v8_fp f = d->fparams[d->segment][!d->y16];
            f.inner = f.inner || !skip;
            if (!d->f_level) f.level = 0;
            d->mbf[d->mbw * mby + mbx] = f;
        }
    }
    if (d->fp.eof) goto done;
    if (d->f_level) v8_loop_filter(d);
    out = malloc(d->w * d->h * 4);                       /* YUV -> RGB (BT.601), the chroma */
    if (out) {                                           /* (half size) mixed 9:3:3:1 */
        unsigned char *o = out;
        int cw = (d->w + 1) >> 1, chh = (d->h + 1) >> 1;
        for (y = 0; y < d->h; y++) {
            int cy = y >> 1, fy = y & 1 ? cy + 1 : cy - 1;
            if (fy < 0) fy = 0;
            if (fy >= chh) fy = chh - 1;
            for (x = 0; x < d->w; x++, o += 4) {
                int cx = x >> 1, fx = x & 1 ? cx + 1 : cx - 1, Y = d->Y[y * d->ystride + x] - 16, U, V;
                const unsigned char *u0, *u1, *v0, *v1;
                if (fx < 0) fx = 0;
                if (fx >= cw) fx = cw - 1;
                u0 = d->U + cy * d->cstride; u1 = d->U + fy * d->cstride;
                v0 = d->V + cy * d->cstride; v1 = d->V + fy * d->cstride;
                U = ((9 * u0[cx] + 3 * u0[fx] + 3 * u1[cx] + u1[fx] + 8) >> 4) - 128;
                V = ((9 * v0[cx] + 3 * v0[fx] + 3 * v1[cx] + v1[fx] + 8) >> 4) - 128;
                o[0] = v8_clip8((298 * Y + 409 * V + 128) >> 8);
                o[1] = v8_clip8((298 * Y - 100 * U - 208 * V + 128) >> 8);
                o[2] = v8_clip8((298 * Y + 516 * U + 128) >> 8);
                o[3] = 255;
            }
        }
        *pw = d->w;
        *ph = d->h;
    }
done:
    free(d->Y); free(d->U); free(d->V); free(d->up); free(d->mbf); free(d);
    return out;
}

/* ================================================================
 * the RIFF container
 * ================================================================ */
static unsigned webp_le24(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16; }
static unsigned webp_le32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (unsigned)p[3] << 24; }

static void webp_unfilter_alpha(unsigned char *a, int w, int h, int filter)
{
    int i, j, n = w * h;
    if (!filter || !w) return;
    for (i = 1; i < w; i++) a[i] += a[i - 1];
    if (filter == 2) { for (i = w; i < n; i++) a[i] += a[i - w]; return; }
    for (i = w; i < n; i += w) {
        a[i] += a[i - w];
        for (j = 1; j < w; j++) {
            if (filter == 1) a[i + j] += a[i + j - 1];
            else {
                int x = a[i + j - 1] + a[i + j - w] - a[i + j - w - 1];
                a[i + j] += (unsigned char)(x < 0 ? 0 : x > 255 ? 255 : x);
            }
        }
    }
}

/* an ALPH chunk -> w*h alpha bytes */
static unsigned char *webp_alpha(const unsigned char *c, int n, int w, int h)
{
    unsigned char *a = 0;
    int comp, filter;
    if (n < 1) return 0;
    comp = c[0] & 3;
    filter = c[0] >> 2 & 3;
    if (comp == 0) {
        if (n - 1 < w * h) return 0;
        a = malloc(w * h);
        if (a) memcpy(a, c + 1, w * h);
    } else if (comp == 1) {                              /* VP8L, its header made up */
        unsigned char *s = malloc(n + 4), *pix;
        int pw, ph, i;
        if (!s) return 0;
        s[0] = 0x2f;
        s[1] = (w - 1) & 0xff;
        s[2] = ((w - 1) >> 8 & 0x3f) | ((h - 1) & 3) << 6;
        s[3] = (h - 1) >> 2 & 0xff;
        s[4] = (h - 1) >> 10 & 0x0f;
        memcpy(s + 5, c + 1, n - 1);
        pix = vp8l_decode(s, n + 4, &pw, &ph);
        free(s);
        if (!pix) return 0;
        a = malloc(w * h);
        if (a) for (i = 0; i < w * h; i++) a[i] = pix[4 * i + 1];
        free(pix);
    }
    if (a) webp_unfilter_alpha(a, w, h, filter);
    return a;
}

/* the size, from the headers */
static int webp_size(const unsigned char *b, int n, int *pw, int *ph)
{
    if (n < 30 || memcmp(b, "RIFF", 4) || memcmp(b + 8, "WEBP", 4)) return 0;
    if (!memcmp(b + 12, "VP8X", 4)) { *pw = webp_le24(b + 24) + 1; *ph = webp_le24(b + 27) + 1; return 1; }
    if (!memcmp(b + 12, "VP8L", 4) && b[20] == 0x2f) {
        unsigned v = webp_le32(b + 21);
        *pw = (v & 0x3fff) + 1; *ph = (v >> 14 & 0x3fff) + 1;
        return 1;
    }
    if (!memcmp(b + 12, "VP8 ", 4)) { *pw = (b[27] & 0x3f) << 8 | b[26]; *ph = (b[29] & 0x3f) << 8 | b[28]; return 1; }
    return 0;
}

/* the frame's chunks (from p, up to end) -> RGBA */
static unsigned char *webp_frame(const unsigned char *b, int p, int end, int *pw, int *ph)
{
    const unsigned char *alph = 0;
    int alen = 0;
    while (p + 8 <= end) {
        int len = webp_le32(b + p + 4);
        const unsigned char *c = b + p + 8;
        if (len < 0 || p + 8 + len > end) len = end - p - 8;
        if (!memcmp(b + p, "ALPH", 4)) { alph = c; alen = len; }
        else if (!memcmp(b + p, "VP8L", 4)) return vp8l_decode(c, len, pw, ph);
        else if (!memcmp(b + p, "VP8 ", 4)) {
            unsigned char *rgba = vp8_decode(c, len, pw, ph);
            if (rgba && alph) {
                unsigned char *a = webp_alpha(alph, alen, *pw, *ph);
                if (a) {
                    int i;
                    for (i = 0; i < *pw * *ph; i++) rgba[4 * i + 3] = a[i];
                    free(a);
                }
            }
            return rgba;
        }
        p += 8 + len + (len & 1);
    }
    return 0;
}

static unsigned *webp_load(const unsigned char *b, int n, int max_w, int max_h, unsigned bg, int *pw, int *ph)
{
    int p = 12, w = 0, h = 0, cw = 0, ch = 0, fx = 0, fy = 0, i, x, y, f = 1;
    unsigned char *rgba = 0;
    unsigned *pix;
    if (n < 20 || memcmp(b, "RIFF", 4) || memcmp(b + 8, "WEBP", 4)) return 0;
    if (webp_le32(b + 4) + 8 < (unsigned)n) n = webp_le32(b + 4) + 8;
    if (!memcmp(b + 12, "VP8X", 4)) {                    /* extended: maybe animated */
        cw = webp_le24(b + 24) + 1;
        ch = webp_le24(b + 27) + 1;
        p = 12 + 8 + 10;
        while (p + 8 <= n) {
            int len = webp_le32(b + p + 4);
            if (!memcmp(b + p, "ANMF", 4) && len >= 16) {          /* the first frame */
                fx = 2 * webp_le24(b + p + 8);
                fy = 2 * webp_le24(b + p + 11);
                rgba = webp_frame(b, p + 8 + 16, p + 8 + len, &w, &h);
                break;
            }
            if (!memcmp(b + p, "ALPH", 4) || !memcmp(b + p, "VP8 ", 4) || !memcmp(b + p, "VP8L", 4)) {
                rgba = webp_frame(b, p, n, &w, &h);
                break;
            }
            p += 8 + len + (len & 1);
        }
    } else rgba = webp_frame(b, 12, n, &w, &h);
    if (!rgba) return 0;
    if (!cw) { cw = w; ch = h; }
    if (cw > 4096 || ch > 4096) { free(rgba); return 0; }
    while ((cw + f - 1) / f > max_w || (ch + f - 1) / f > max_h) f++;
    *pw = cw / f ? cw / f : 1;
    *ph = ch / f ? ch / f : 1;
    pix = malloc(*pw * *ph * 4);
    if (!pix) { free(rgba); return 0; }
    for (i = 0; i < *pw * *ph; i++) pix[i] = bg;
    for (y = 0; y < *ph; y++)
        for (x = 0; x < *pw; x++) {
            int sx = x * f - fx, sy = y * f - fy;
            const unsigned char *s;
            unsigned a, r, g, bb;
            if (sx < 0 || sy < 0 || sx >= w || sy >= h) continue;
            s = rgba + 4 * (sy * w + sx);
            a = s[3];
            r = (s[0] * a + ((bg >> 16) & 255) * (255 - a)) / 255;
            g = (s[1] * a + ((bg >> 8) & 255) * (255 - a)) / 255;
            bb = (s[2] * a + (bg & 255) * (255 - a)) / 255;
            pix[y * *pw + x] = r << 16 | g << 8 | bb;
        }
    free(rgba);
    return pix;
}

#endif
