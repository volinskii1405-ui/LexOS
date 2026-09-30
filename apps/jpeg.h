/* jpeg.h - JPEG pictures for LexOS programs in C (the web's photos):
 *
 *   int w, h;
 *   unsigned *pix = jpeg_load(data, n, maxw, maxh, &w, &h);
 *   -> malloc'd 0xRRGGBB pixels, w x h - no bigger than maxw x maxh
 *      (made smaller as it's read, so a big photo needs no more memory
 *      than what's shown); 0 if it isn't one this reads
 *
 * Baseline (and extended) Huffman JPEGs: gray or YCbCr, any sampling,
 * restart markers. A progressive one is shown from its first pass -
 * the average of each 8x8 block (blurry, but all of it, and in little
 * memory). Not: arithmetic coding, 12-bit, CMYK. */
#ifndef JPEG_H
#define JPEG_H
#include "lexos.h"

struct jp_huff { unsigned char look_len[512], look_val[512]; int maxcode[18], valptr[17], mincode[17]; unsigned char val[256]; };
struct jp_comp { int id, h, v, tq, td, ta, bw, bh, pred; short *dc, *coef; };

static const unsigned char *jp_d;
static int jp_n, jp_pos, jp_bits, jp_nbits, jp_marker;
static unsigned short jp_q[4][64];
static struct jp_huff jp_hdc[4], jp_hac[4];
static struct jp_comp jp_c[3];
static int jp_nc, jp_w, jp_h, jp_hmax, jp_vmax, jp_mx, jp_my, jp_ri, jp_prog, jp_full, jp_eobrun, jp_rgb;
#define JP_COEF_MAX (700 * 1024)                /* a progressive one, all of it: this much at most */
static int jp_ow, jp_oh;
static unsigned *jp_out;

static const unsigned char jp_zz[64] = {
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21,
    28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61,
    54, 47, 55, 62, 63 };

static int jp_u16(int p) { return jp_d[p] << 8 | jp_d[p + 1]; }

static void jp_build(struct jp_huff *h, const unsigned char *counts, const unsigned char *vals)
{
    int code = 0, k = 0, len, i;
    memset(h->look_len, 0, sizeof h->look_len);
    for (len = 1; len <= 16; len++) {
        h->valptr[len] = k;
        h->mincode[len] = code;
        for (i = 0; i < counts[len - 1] && k < 256; i++) {
            h->val[k] = vals[k];
            if (len <= 9) {                               /* the short ones: looked up */
                int j, shift = 9 - len;
                for (j = 0; j < 1 << shift; j++) {
                    h->look_len[(code << shift) | j] = len;
                    h->look_val[(code << shift) | j] = vals[k];
                }
            }
            k++;
            code++;
        }
        h->maxcode[len] = counts[len - 1] ? code - 1 : -1;
        code <<= 1;
    }
    h->maxcode[17] = 0x7FFFFFFF;
}

/* the entropy-coded data: bits, with 0xFF 0x00 as 0xFF and a marker
 * ending it (zeros from there) */
static void jp_fill(void)
{
    while (jp_nbits <= 24) {
        int c = 0;
        if (!jp_marker && jp_pos < jp_n) {
            c = jp_d[jp_pos++];
            if (c == 0xFF) {
                int c2 = jp_pos < jp_n ? jp_d[jp_pos] : 0;
                if (c2 == 0) jp_pos++;
                else { jp_marker = c2; jp_pos--; c = 0; }
            }
        }
        jp_bits |= c << (24 - jp_nbits);
        jp_nbits += 8;
    }
}
static int jp_getbits(int n)
{
    int v;
    if (!n) return 0;
    jp_fill();
    v = (unsigned)jp_bits >> (32 - n);
    jp_bits <<= n;
    jp_nbits -= n;
    return v;
}
static int jp_decode(struct jp_huff *h)
{
    int look, len, code;
    jp_fill();
    look = (unsigned)jp_bits >> 23;
    if ((len = h->look_len[look])) {
        jp_bits <<= len;
        jp_nbits -= len;
        return h->look_val[look];
    }
    code = jp_getbits(9);
    for (len = 10; len <= 16; len++) {
        code = code << 1 | jp_getbits(1);
        if (h->maxcode[len] >= 0 && code <= h->maxcode[len]) return h->val[h->valptr[len] + code - h->mincode[len]];
    }
    return 0;
}
static int jp_extend(int v, int t) { return t && v < 1 << (t - 1) ? v - (1 << t) + 1 : v; }

/* after a restart marker: bits and predictions afresh */
static void jp_restart(void)
{
    int i;
    jp_bits = jp_nbits = 0;
    if (jp_marker >= 0xD0 && jp_marker <= 0xD7) { jp_pos += 2; jp_marker = 0; }
    else {                                                /* (look for it) */
        while (jp_pos + 1 < jp_n && !(jp_d[jp_pos] == 0xFF && jp_d[jp_pos + 1] >= 0xD0 && jp_d[jp_pos + 1] <= 0xD7)) jp_pos++;
        if (jp_pos + 1 < jp_n) jp_pos += 2;
        jp_marker = 0;
    }
    for (i = 0; i < jp_nc; i++) jp_c[i].pred = 0;
}

/* an 8x8 block, its 64 coefficients -> 64 pixels (out, stride) */
static int jp_cos[64];                                    /* cos((2x+1)u pi/16) * C(u) * 4096 */
static void jp_idct(const int *in, unsigned char *out, int stride)
{
    int tmp[64], x, y, u;
    for (y = 0; y < 8; y++)                               /* rows */
        for (x = 0; x < 8; x++) {
            int s = 0;
            for (u = 0; u < 8; u++) if (in[y * 8 + u]) s += in[y * 8 + u] * jp_cos[x * 8 + u];
            tmp[y * 8 + x] = s >> 8;
        }
    for (x = 0; x < 8; x++)                               /* columns */
        for (y = 0; y < 8; y++) {
            int s = 0, v;
            for (u = 0; u < 8; u++) s += tmp[u * 8 + x] * jp_cos[y * 8 + u];
            v = ((s + (1 << 17)) >> 18) + 128;            /* (/65536 the tables, /4 the transform's) */
            out[y * stride + x] = v < 0 ? 0 : v > 255 ? 255 : v;
        }
}
static void jp_tables(void)
{
    static const int c[8] = { 4096, 4017, 3784, 3406, 2896, 2276, 1567, 799 };   /* cos(k pi/16)*4096 */
    int x, u;
    if (jp_cos[1]) return;
    for (x = 0; x < 8; x++)
        for (u = 0; u < 8; u++) {
            int k = ((2 * x + 1) * u) % 32, sgn = 1, v;
            if (k > 16) k = 32 - k;                       /* cos(k pi/16), k 0..16 */
            if (k > 8) { k = 16 - k; sgn = -1; }
            v = k == 8 ? 0 : sgn * c[k];
            if (!u) v = v * 2896 / 4096;                  /* C(0) = 1/sqrt2 */
            jp_cos[x * 8 + u] = v;
        }
}

/* an MCU row's pixels (each component's plane) -> the output rows it covers */
static unsigned char *jp_plane[3];
static int jp_pw[3];
static void jp_emit_rows(int mrow)
{
    int y0 = mrow * jp_vmax * 8, y1 = y0 + jp_vmax * 8, oy;
    for (oy = y0 * jp_oh / jp_h; oy < jp_oh; oy++) {
        int sy = oy * jp_h / jp_oh, ox;
        if (sy < y0) continue;
        if (sy >= y1) break;
        for (ox = 0; ox < jp_ow; ox++) {
            int sx = ox * jp_w / jp_ow, r, g, b;
            int yy = jp_plane[0][(sy - y0) * jp_c[0].v / jp_vmax * jp_pw[0] + sx * jp_c[0].h / jp_hmax];
            if (jp_nc == 3) {
                int cb = jp_plane[1][(sy - y0) * jp_c[1].v / jp_vmax * jp_pw[1] + sx * jp_c[1].h / jp_hmax] - 128;
                int cr = jp_plane[2][(sy - y0) * jp_c[2].v / jp_vmax * jp_pw[2] + sx * jp_c[2].h / jp_hmax] - 128;
                if (jp_rgb) { r = yy; g = cb + 128; b = cr + 128; }
                else {
                    r = yy + ((91881 * cr) >> 16);
                    g = yy - ((22554 * cb + 46802 * cr) >> 16);
                    b = yy + ((116130 * cb) >> 16);
                }
                r = r < 0 ? 0 : r > 255 ? 255 : r;
                g = g < 0 ? 0 : g > 255 ? 255 : g;
                b = b < 0 ? 0 : b > 255 ? 255 : b;
            } else r = g = b = yy;
            jp_out[oy * jp_ow + ox] = r << 16 | g << 8 | b;
        }
    }
}

/* one block of component c: its coefficients (baseline) */
static int jp_block(int c, int *coef)
{
    struct jp_comp *k = &jp_c[c];
    int t, i, v;
    memset(coef, 0, 64 * sizeof(int));
    t = jp_decode(&jp_hdc[k->td]);
    v = t ? jp_extend(jp_getbits(t), t) : 0;
    k->pred += v;
    coef[0] = k->pred * jp_q[k->tq][0];
    for (i = 1; i < 64;) {
        int rs = jp_decode(&jp_hac[k->ta]), r = rs >> 4, s = rs & 15;
        if (!s) { if (r != 15) break; i += 16; continue; }
        i += r;
        if (i > 63) break;
        coef[jp_zz[i]] = jp_extend(jp_getbits(s), s) * jp_q[k->tq][i];
        i++;
    }
    return 0;
}

/* the scan of a baseline picture: MCU after MCU, each row's out */
static int jp_scan_baseline(void)
{
    int mx, my, c, i, coef[64], left = jp_ri;
    for (c = 0; c < jp_nc; c++) {
        jp_pw[c] = jp_mx * jp_c[c].h * 8;
        jp_plane[c] = malloc(jp_pw[c] * jp_c[c].v * 8);
        if (!jp_plane[c]) { while (c--) free(jp_plane[c]); return -1; }
    }
    for (my = 0; my < jp_my; my++) {
        for (mx = 0; mx < jp_mx; mx++) {
            if (jp_ri && !left) { jp_restart(); left = jp_ri; }
            for (c = 0; c < jp_nc; c++)
                for (i = 0; i < jp_c[c].h * jp_c[c].v; i++) {
                    int bx = mx * jp_c[c].h + i % jp_c[c].h, by = i / jp_c[c].h;
                    jp_block(c, coef);
                    jp_idct(coef, jp_plane[c] + by * 8 * jp_pw[c] + bx * 8, jp_pw[c]);
                }
            left--;
        }
        jp_emit_rows(my);
    }
    for (c = 0; c < jp_nc; c++) free(jp_plane[c]);
    return 0;
}

/* a progressive picture's DC scan (the first pass): each block's average */
static int jp_scan_dc(int *ids, int ns, int al)
{
    int left = jp_ri, c;
    if (ns == 1) {                                        /* one component: its blocks in order */
        struct jp_comp *k = &jp_c[ids[0]];
        int bw = (jp_w * k->h / jp_hmax + 7) / 8, bh = (jp_h * k->v / jp_vmax + 7) / 8, bx, by;
        for (by = 0; by < bh; by++)
            for (bx = 0; bx < bw; bx++) {
                int t, v;
                if (jp_ri && !left) { jp_restart(); left = jp_ri; }
                t = jp_decode(&jp_hdc[k->td]);
                v = t ? jp_extend(jp_getbits(t), t) : 0;
                k->pred += v;
                k->dc[by * k->bw + bx] = k->pred << al;
                left--;
            }
        return 0;
    }
    {
        int mx, my, i;
        for (my = 0; my < jp_my; my++)
            for (mx = 0; mx < jp_mx; mx++) {
                if (jp_ri && !left) { jp_restart(); left = jp_ri; }
                for (i = 0; i < ns; i++) {
                    struct jp_comp *k = &jp_c[ids[i]];
                    int j;
                    for (j = 0; j < k->h * k->v; j++) {
                        int bx = mx * k->h + j % k->h, by = my * k->v + j / k->h, t, v;
                        t = jp_decode(&jp_hdc[k->td]);
                        v = t ? jp_extend(jp_getbits(t), t) : 0;
                        k->pred += v;
                        if (bx < k->bw && by < k->bh) k->dc[by * k->bw + bx] = k->pred << al;
                    }
                }
                left--;
            }
    }
    (void)c;
    return 0;
}
/* the averages -> the picture, smoothly between them */
static void jp_from_dc(void)
{
    int ox, oy, c;
    for (oy = 0; oy < jp_oh; oy++)
        for (ox = 0; ox < jp_ow; ox++) {
            int v[3], r, g, b;
            for (c = 0; c < jp_nc; c++) {
                struct jp_comp *k = &jp_c[c];
                /* where in its blocks, in 1/256ths (from the blocks' middles) */
                int fx = ((ox * jp_w / jp_ow) * k->h / jp_hmax * 32) - 128;
                int fy = ((oy * jp_h / jp_oh) * k->v / jp_vmax * 32) - 128;
                int x0, y0, ax, ay, x1, y1, q = jp_q[k->tq][0], p00, p01, p10, p11;
                if (fx < 0) fx = 0;
                if (fy < 0) fy = 0;
                x0 = fx >> 8; y0 = fy >> 8; ax = fx & 255; ay = fy & 255;
                if (x0 >= k->bw) x0 = k->bw - 1;
                if (y0 >= k->bh) y0 = k->bh - 1;
                x1 = x0 + 1 < k->bw ? x0 + 1 : x0;
                y1 = y0 + 1 < k->bh ? y0 + 1 : y0;
                p00 = k->dc[y0 * k->bw + x0]; p01 = k->dc[y0 * k->bw + x1];
                p10 = k->dc[y1 * k->bw + x0]; p11 = k->dc[y1 * k->bw + x1];
                v[c] = ((p00 * (256 - ax) + p01 * ax) * (256 - ay) + (p10 * (256 - ax) + p11 * ax) * ay) >> 16;
                v[c] = v[c] * q / 8 + 128;
            }
            if (jp_nc == 3) {
                int cb = v[1] - 128, cr = v[2] - 128;
                r = v[0] + ((91881 * cr) >> 16);
                g = v[0] - ((22554 * cb + 46802 * cr) >> 16);
                b = v[0] + ((116130 * cb) >> 16);
            } else r = g = b = v[0];
            r = r < 0 ? 0 : r > 255 ? 255 : r;
            g = g < 0 ? 0 : g > 255 ? 255 : g;
            b = b < 0 ? 0 : b > 255 ? 255 : b;
            jp_out[oy * jp_ow + ox] = r << 16 | g << 8 | b;
        }
}

/* ---- a progressive picture, all of it: each pass into the coefficients ---- */
static void jp_prog_block(struct jp_comp *k, short *b, int ss, int se, int ah, int al)
{
    if (ss == 0) {                                        /* DC */
        if (!ah) {
            int t = jp_decode(&jp_hdc[k->td]);
            k->pred += t ? jp_extend(jp_getbits(t), t) : 0;
            b[0] = k->pred * (1 << al);
        } else if (jp_getbits(1)) b[0] += 1 << al;
        return;
    }
    if (!ah) {                                            /* AC, the first time */
        int kk = ss;
        if (jp_eobrun) { jp_eobrun--; return; }
        do {
            int rs = jp_decode(&jp_hac[k->ta]), s = rs & 15, r = rs >> 4;
            if (!s) {
                if (r < 15) { jp_eobrun = 1 << r; if (r) jp_eobrun += jp_getbits(r); jp_eobrun--; break; }
                kk += 16;
            } else {
                kk += r;
                if (kk > 63) break;
                b[jp_zz[kk++]] = jp_extend(jp_getbits(s), s) * (1 << al);
            }
        } while (kk <= se);
        return;
    }
    {                                                     /* AC, a bit more of each */
        short bit = 1 << al;
        int kk;
        if (jp_eobrun) {
            jp_eobrun--;
            for (kk = ss; kk <= se; kk++) {
                short *q = &b[jp_zz[kk]];
                if (*q && jp_getbits(1) && !(*q & bit)) *q += *q > 0 ? bit : -bit;
            }
            return;
        }
        kk = ss;
        do {
            int rs = jp_decode(&jp_hac[k->ta]), s = rs & 15, r = rs >> 4;
            if (!s) {
                if (r < 15) { jp_eobrun = (1 << r) - 1; if (r) jp_eobrun += jp_getbits(r); r = 64; }
            } else s = jp_getbits(1) ? bit : -bit;
            while (kk <= se) {
                short *q = &b[jp_zz[kk++]];
                if (*q) { if (jp_getbits(1) && !(*q & bit)) *q += *q > 0 ? bit : -bit; }
                else { if (!r) { *q = s; break; } r--; }
            }
        } while (kk <= se);
    }
}
static void jp_scan_prog(int *ids, int ns, int ss, int se, int ah, int al)
{
    int left = jp_ri;
    jp_eobrun = 0;
    if (ns == 1) {                                        /* one component: its blocks in order */
        struct jp_comp *k = &jp_c[ids[0]];
        int bw = (jp_w * k->h / jp_hmax + 7) / 8, bh = (jp_h * k->v / jp_vmax + 7) / 8, bx, by;
        if (jp_nc == 1) { bw = (jp_w + 7) / 8; bh = (jp_h + 7) / 8; }
        for (by = 0; by < bh; by++)
            for (bx = 0; bx < bw; bx++) {
                if (jp_ri && !left) { jp_restart(); jp_eobrun = 0; left = jp_ri; }
                if (bx < k->bw && by < k->bh) jp_prog_block(k, k->coef + (by * k->bw + bx) * 64, ss, se, ah, al);
                left--;
            }
        return;
    }
    {
        int mx, my, i, j;
        for (my = 0; my < jp_my; my++)
            for (mx = 0; mx < jp_mx; mx++) {
                if (jp_ri && !left) { jp_restart(); jp_eobrun = 0; left = jp_ri; }
                for (i = 0; i < ns; i++) {
                    struct jp_comp *k = &jp_c[ids[i]];
                    for (j = 0; j < k->h * k->v; j++) {
                        int bx = mx * k->h + j % k->h, by = my * k->v + j / k->h;
                        jp_prog_block(k, k->coef + (by * k->bw + bx) * 64, ss, se, ah, al);
                    }
                }
                left--;
            }
    }
}
/* all the passes in: each block's pixels, a row of MCUs at a time */
static int jp_finish_prog(void)
{
    int c, my, mx, i, coef[64];
    for (c = 0; c < jp_nc; c++) {
        jp_pw[c] = jp_mx * jp_c[c].h * 8;
        jp_plane[c] = malloc(jp_pw[c] * jp_c[c].v * 8);
        if (!jp_plane[c]) { while (c--) free(jp_plane[c]); return -1; }
    }
    for (my = 0; my < jp_my; my++) {
        for (c = 0; c < jp_nc; c++)
            for (mx = 0; mx < jp_mx; mx++)
                for (i = 0; i < jp_c[c].h * jp_c[c].v; i++) {
                    int bx = mx * jp_c[c].h + i % jp_c[c].h, by = my * jp_c[c].v + i / jp_c[c].h, z;
                    short *b = jp_c[c].coef + (by * jp_c[c].bw + bx) * 64;
                    for (z = 0; z < 64; z++) coef[jp_zz[z]] = b[jp_zz[z]] * jp_q[jp_c[c].tq][z];
                    jp_idct(coef, jp_plane[c] + (i / jp_c[c].h) * 8 * jp_pw[c] + bx * 8, jp_pw[c]);
                }
        jp_emit_rows(my);
    }
    for (c = 0; c < jp_nc; c++) free(jp_plane[c]);
    return 0;
}

static unsigned *jpeg_load(const unsigned char *d, int n, int maxw, int maxh, int *pw, int *ph)
{
    int p = 2, have_frame = 0, done = 0, dc_scans = 0, i;
    if (n < 4 || d[0] != 0xFF || d[1] != 0xD8) return 0;
    jp_d = d; jp_n = n; jp_ri = 0; jp_prog = 0; jp_out = 0; jp_nc = 0;
    for (i = 0; i < 3; i++) jp_c[i].dc = 0;
    jp_tables();
    while (p + 4 <= n && !done) {
        int m, len;
        if (d[p] != 0xFF) { p++; continue; }
        m = d[p + 1];
        if (m == 0xFF) { p++; continue; }
        if (m == 0xD8 || (m >= 0xD0 && m <= 0xD7) || m == 0x01) { p += 2; continue; }
        if (m == 0xD9) break;
        len = jp_u16(p + 2);
        if (p + 2 + len > n) break;
        if (m == 0xDB) {                                  /* quantization tables */
            int q = p + 4, e = p + 2 + len;
            while (q < e) {
                int pq = d[q] >> 4, tq = d[q] & 3, k;
                q++;
                for (k = 0; k < 64; k++) jp_q[tq][k] = pq ? jp_u16(q + k * 2) : d[q + k];
                q += pq ? 128 : 64;
            }
        } else if (m == 0xC4) {                           /* Huffman tables */
            int q = p + 4, e = p + 2 + len;
            while (q + 17 <= e) {
                int tc = d[q] >> 4, th = d[q] & 3, total = 0, k;
                for (k = 0; k < 16; k++) total += d[q + 1 + k];
                if (q + 17 + total > e || total > 256) break;
                jp_build(tc ? &jp_hac[th] : &jp_hdc[th], d + q + 1, d + q + 17);
                q += 17 + total;
            }
        } else if (m == 0xDD) jp_ri = jp_u16(p + 4);      /* restart interval */
        else if (m == 0xC0 || m == 0xC1 || m == 0xC2) {   /* the frame */
            if (d[p + 4] != 8) return 0;                  /* (8-bit only) */
            jp_prog = m == 0xC2;
            jp_h = jp_u16(p + 5);
            jp_w = jp_u16(p + 7);
            jp_nc = d[p + 9];
            if ((jp_nc != 1 && jp_nc != 3) || jp_w <= 0 || jp_h <= 0 || jp_w > 16384 || jp_h > 16384) return 0;
            jp_hmax = jp_vmax = 1;
            for (i = 0; i < jp_nc; i++) {
                jp_c[i].id = d[p + 10 + i * 3];
                jp_c[i].h = d[p + 11 + i * 3] >> 4;
                jp_c[i].v = d[p + 11 + i * 3] & 15;
                jp_c[i].tq = d[p + 12 + i * 3] & 3;
                if (jp_c[i].h < 1 || jp_c[i].h > 4 || jp_c[i].v < 1 || jp_c[i].v > 4) return 0;
                if (jp_c[i].h > jp_hmax) jp_hmax = jp_c[i].h;
                if (jp_c[i].v > jp_vmax) jp_vmax = jp_c[i].v;
            }
            if (jp_nc == 1) jp_c[0].h = jp_c[0].v = jp_hmax = jp_vmax = 1;   /* (one: a block an MCU) */
            jp_rgb = jp_nc == 3 && jp_c[0].id == 'R' && jp_c[1].id == 'G' && jp_c[2].id == 'B';
            jp_mx = (jp_w + jp_hmax * 8 - 1) / (jp_hmax * 8);
            jp_my = (jp_h + jp_vmax * 8 - 1) / (jp_vmax * 8);
            jp_ow = jp_w; jp_oh = jp_h;                   /* the size shown */
            if (jp_ow > maxw) { jp_oh = jp_oh * maxw / jp_ow; jp_ow = maxw; }
            if (jp_oh > maxh) { jp_ow = jp_ow * maxh / jp_oh; jp_oh = maxh; }
            if (jp_ow < 1) jp_ow = 1;
            if (jp_oh < 1) jp_oh = 1;
            for (;;) {                                    /* (as memory lets it be) */
                jp_out = malloc(jp_ow * jp_oh * 4);
                if (jp_out) break;
                if (jp_ow < 32 || jp_oh < 32) return 0;
                jp_ow = jp_ow * 3 / 4; jp_oh = jp_oh * 3 / 4;
            }
            jp_full = 0;
            jp_eobrun = 0;
            if (jp_prog) {
                int total = 0;
                for (i = 0; i < jp_nc; i++) {
                    jp_c[i].bw = jp_mx * jp_c[i].h;
                    jp_c[i].bh = jp_my * jp_c[i].v;
                    jp_c[i].coef = 0;
                    total += jp_c[i].bw * jp_c[i].bh * 128;
                }
                if (total <= JP_COEF_MAX) {               /* all of it: every coefficient */
                    jp_full = 1;
                    for (i = 0; i < jp_nc; i++) {
                        jp_c[i].coef = malloc(jp_c[i].bw * jp_c[i].bh * 128);
                        if (!jp_c[i].coef) { jp_full = 0; break; }
                        memset(jp_c[i].coef, 0, jp_c[i].bw * jp_c[i].bh * 128);
                    }
                    if (!jp_full) for (i = 0; i < jp_nc; i++) { free(jp_c[i].coef); jp_c[i].coef = 0; }
                }
                if (!jp_full)
                    for (i = 0; i < jp_nc; i++) {         /* too big: each block's average */
                        jp_c[i].dc = malloc(jp_c[i].bw * jp_c[i].bh * sizeof(short));
                        if (!jp_c[i].dc) goto fail;
                        memset(jp_c[i].dc, 0, jp_c[i].bw * jp_c[i].bh * sizeof(short));
                    }
            }
            have_frame = 1;
        } else if (m >= 0xC3 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) return 0;   /* (lossless, arithmetic) */
        else if (m == 0xDA) {                             /* a scan */
            int ns = d[p + 4], ids[3], ss, se, al;
            if (!have_frame || ns < 1 || ns > 3) goto fail;
            for (i = 0; i < ns; i++) {
                int cid = d[p + 5 + i * 2], k;
                for (k = 0; k < jp_nc; k++) if (jp_c[k].id == cid) break;
                if (k == jp_nc) goto fail;
                ids[i] = k;
                jp_c[k].td = d[p + 6 + i * 2] >> 4;
                jp_c[k].ta = d[p + 6 + i * 2] & 15;
                jp_c[k].pred = 0;
            }
            ss = d[p + 5 + ns * 2];
            se = d[p + 6 + ns * 2];
            al = d[p + 7 + ns * 2] & 15;
            jp_pos = p + 2 + len;
            jp_bits = jp_nbits = jp_marker = 0;
            if (!jp_prog) {
                if (ns != jp_nc) goto fail;               /* (all in one scan: baseline's way) */
                if (jp_scan_baseline() < 0) goto fail;
                done = 1;
                break;
            }
            if (jp_full) {                                /* every pass, into the coefficients */
                jp_scan_prog(ids, ns, ss, se, d[p + 7 + ns * 2] >> 4, al);
            } else if (ss == 0 && se == 0 && !(d[p + 7 + ns * 2] >> 4)) {   /* a first DC pass */
                jp_scan_dc(ids, ns, al);
                dc_scans += ns;
            } else if (dc_scans >= jp_nc) { jp_from_dc(); done = 1; break; }
            if (jp_full) { p = jp_pos; while (p + 1 < n && !(d[p] == 0xFF && d[p + 1] != 0 && !(d[p + 1] >= 0xD0 && d[p + 1] <= 0xD7))) p++; continue; }
            /* past the scan's data: to the next marker */
            p = jp_pos;
            while (p + 1 < n && !(d[p] == 0xFF && d[p + 1] != 0 && !(d[p + 1] >= 0xD0 && d[p + 1] <= 0xD7))) p++;
            continue;
        }
        p += 2 + len;
    }
    if (!done && jp_full) { if (jp_finish_prog() == 0) done = 1; }
    if (!done && jp_prog && !jp_full && dc_scans >= jp_nc) { jp_from_dc(); done = 1; }
    if (!done) goto fail;
    for (i = 0; i < 3; i++) { free(jp_c[i].dc); jp_c[i].dc = 0; free(jp_c[i].coef); jp_c[i].coef = 0; }
    *pw = jp_ow;
    *ph = jp_oh;
    return jp_out;
fail:
    for (i = 0; i < 3; i++) { free(jp_c[i].dc); jp_c[i].dc = 0; free(jp_c[i].coef); jp_c[i].coef = 0; }
    free(jp_out);
    jp_out = 0;
    return 0;
}

#endif
