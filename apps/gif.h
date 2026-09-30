/* gif.h - GIF pictures for LexOS programs in C: the first frame (an
 * animation stands still), its own or the global colors, transparency
 * (the background given shows through), interlaced or not.
 *
 *   unsigned *pix = gif_load(data, n, maxw, maxh, bg, &w, &h);
 *   -> malloc'd 0xRRGGBB pixels, no bigger than maxw x maxh (made
 *      smaller row by row as it's read); 0 if it isn't one */
#ifndef GIF_H
#define GIF_H
#include "lexos.h"

static const unsigned char *gf_d;
static int gf_n, gf_pos;
static unsigned gf_pal[256];
static unsigned *gf_out;
static unsigned char *gf_row;
static int gf_sw, gf_sh, gf_ow, gf_oh, gf_ix, gf_iy, gf_iw, gf_ih, gf_trans, gf_inter, gf_x, gf_y, gf_pass;
static unsigned gf_bg;

/* a row of the frame done: into the rows of the output it lands on */
static void gf_row_done(int iy)
{
    int sy = gf_iy + iy, oy;
    for (oy = sy * gf_oh / gf_sh; oy < gf_oh && oy * gf_sh / gf_oh <= sy; oy++) {
        int ox;
        if (oy * gf_sh / gf_oh != sy) continue;
        for (ox = 0; ox < gf_ow; ox++) {
            int sx = ox * gf_sw / gf_ow - gf_ix;
            if (sx < 0 || sx >= gf_iw) continue;
            if (gf_row[sx] == gf_trans) continue;
            gf_out[oy * gf_ow + ox] = gf_pal[gf_row[sx]];
        }
    }
}
/* a pixel of the frame, in the order they come */
static void gf_pixel(int c)
{
    static const int start[4] = { 0, 4, 2, 1 }, step[4] = { 8, 8, 4, 2 };
    if (gf_y >= gf_ih) return;
    gf_row[gf_x++] = c;
    if (gf_x < gf_iw) return;
    gf_row_done(gf_y);
    gf_x = 0;
    if (!gf_inter) { gf_y++; return; }
    gf_y += step[gf_pass];
    while (gf_y >= gf_ih && gf_pass < 3) { gf_pass++; gf_y = start[gf_pass]; }
}

static int gf_lzw(int min)
{
    static unsigned short prefix[4096];
    static unsigned char suffix[4096], stack[4097];
    int clear = 1 << min, end = clear + 1, next = clear + 2, size = min + 1, old = -1, first = 0;
    unsigned bits = 0;
    int nbits = 0, block = 0;
    if (min < 2 || min > 8) return -1;
    for (;;) {
        int code, in, sp = 0;
        while (nbits < size) {                            /* bytes from the sub-blocks */
            if (!block) {
                if (gf_pos >= gf_n) return 0;
                block = gf_d[gf_pos++];
                if (!block) return 0;
            }
            if (gf_pos >= gf_n) return 0;
            bits |= gf_d[gf_pos++] << nbits;
            nbits += 8;
            block--;
        }
        code = bits & ((1 << size) - 1);
        bits >>= size;
        nbits -= size;
        if (code == clear) { size = min + 1; next = clear + 2; old = -1; continue; }
        if (code == end) break;
        if (old < 0) {                                    /* the first after a clear */
            if (code >= clear) return -1;
            gf_pixel(code);
            old = first = code;
            continue;
        }
        in = code;
        if (code >= next) {                               /* not there yet: old's, and its first */
            if (code > next) return -1;
            stack[sp++] = first;
            code = old;
        }
        while (code >= clear) {
            if (sp >= 4096) return -1;
            stack[sp++] = suffix[code];
            code = prefix[code];
        }
        first = code;
        stack[sp++] = code;
        while (sp) gf_pixel(stack[--sp]);
        if (next < 4096) {
            prefix[next] = old;
            suffix[next] = first;
            next++;
            if (next == 1 << size && size < 12) size++;
        }
        old = in;
    }
    /* (the rest of the sub-blocks: past them) */
    while (block && gf_pos < gf_n) { gf_pos += block; block = gf_pos < gf_n ? gf_d[gf_pos++] : 0; }
    return 0;
}

static unsigned *gif_load(const unsigned char *d, int n, int maxw, int maxh, unsigned bg, int *pw, int *ph)
{
    int flags, i, gct = 0;
    if (n < 13 || memcmp(d, "GIF8", 4)) return 0;
    gf_d = d; gf_n = n;
    gf_sw = d[6] | d[7] << 8;
    gf_sh = d[8] | d[9] << 8;
    if (gf_sw <= 0 || gf_sh <= 0) return 0;
    flags = d[10];
    gf_pos = 13;
    gf_trans = -1;
    gf_bg = bg;
    if (flags & 0x80) {                                   /* the global colors */
        gct = 2 << (flags & 7);
        if (gf_pos + gct * 3 > n) return 0;
        for (i = 0; i < gct; i++) gf_pal[i] = d[gf_pos + i * 3] << 16 | d[gf_pos + i * 3 + 1] << 8 | d[gf_pos + i * 3 + 2];
        gf_pos += gct * 3;
    }
    gf_ow = gf_sw; gf_oh = gf_sh;
    if (gf_ow > maxw) { gf_oh = gf_oh * maxw / gf_ow; gf_ow = maxw; }
    if (gf_oh > maxh) { gf_ow = gf_ow * maxh / gf_oh; gf_oh = maxh; }
    if (gf_ow < 1) gf_ow = 1;
    if (gf_oh < 1) gf_oh = 1;
    for (;;) {                                            /* (as memory lets it be) */
        gf_out = malloc(gf_ow * gf_oh * 4);
        if (gf_out) break;
        if (gf_ow < 32 || gf_oh < 32) return 0;
        gf_ow = gf_ow * 3 / 4; gf_oh = gf_oh * 3 / 4;
    }
    for (i = 0; i < gf_ow * gf_oh; i++) gf_out[i] = bg;
    while (gf_pos < n) {
        int b = d[gf_pos++];
        if (b == 0x21) {                                  /* an extension */
            int label = gf_pos < n ? d[gf_pos++] : 0;
            if (label == 0xF9 && gf_pos + 5 < n && d[gf_pos] >= 4) {    /* transparency */
                if (d[gf_pos + 1] & 1) gf_trans = d[gf_pos + 4];
            }
            while (gf_pos < n && d[gf_pos]) gf_pos += d[gf_pos] + 1;
            gf_pos++;
        } else if (b == 0x2C) {                           /* the frame */
            int lf, r;
            if (gf_pos + 9 > n) break;
            gf_ix = d[gf_pos] | d[gf_pos + 1] << 8;
            gf_iy = d[gf_pos + 2] | d[gf_pos + 3] << 8;
            gf_iw = d[gf_pos + 4] | d[gf_pos + 5] << 8;
            gf_ih = d[gf_pos + 6] | d[gf_pos + 7] << 8;
            lf = d[gf_pos + 8];
            gf_pos += 9;
            if (lf & 0x80) {                              /* its own colors */
                int lct = 2 << (lf & 7);
                if (gf_pos + lct * 3 > n) break;
                for (i = 0; i < lct; i++) gf_pal[i] = d[gf_pos + i * 3] << 16 | d[gf_pos + i * 3 + 1] << 8 | d[gf_pos + i * 3 + 2];
                gf_pos += lct * 3;
            } else if (!gct) break;
            if (gf_iw <= 0 || gf_ih <= 0 || gf_iw > 8192) break;
            gf_inter = lf & 0x40;
            gf_x = gf_y = gf_pass = 0;
            gf_row = malloc(gf_iw);
            if (!gf_row) break;
            r = gf_pos < n ? gf_lzw(d[gf_pos++]) : -1;
            free(gf_row);
            if (r < 0 && !gf_y) break;
            *pw = gf_ow;
            *ph = gf_oh;
            return gf_out;                                /* (the first frame is enough) */
        } else break;
    }
    free(gf_out);
    return 0;
}

#endif
