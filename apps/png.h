/* png.h - PNG pictures, read: for LexOS programs, and (as
 * /SYSTEM/PNG.BIN, apps/pngmod.c) for the desktop itself.
 *
 *   int n = png_to_bmp(png, png_len, out, out_max, max_w, max_h);
 *
 * turns a PNG file into a 24-bit .BMP file (the kind everything in
 * LexOS already reads) at out -> its length, or <0 if it isn't a PNG
 * this can read / out's too small. A picture bigger than max_w x max_h
 * comes out shrunk by a whole factor (the pixels of each square
 * averaged; interlaced ones: every f-th). Transparent parts are laid
 * over white. png[] is used as working space (the compressed data is
 * gathered in it): it's not a PNG any more afterwards.
 *
 * All of PNG's kinds: grey, RGB, palette (with its transparency),
 * grey + alpha, RGBA; 1, 2, 4, 8 and 16 bits; Adam7 interlacing. Widths
 * up to 4096. It doesn't check the CRCs, nor use gamma or colour
 * profiles. The data comes out of the inflater a byte at a time and is
 * put together a row at a time - no buffer for the whole picture. */
#ifndef PNG_H
#define PNG_H

#define PNG_MAX_W 4096

typedef unsigned char png_u8;

/* ---- the picture being put together ---- */
static int pg_w, pg_h, pg_depth, pg_ctype, pg_inter, pg_chan, pg_bpp;   /* bpp: bytes a pixel (filters) */
static png_u8 pg_pal[256 * 4];
static int pg_npal, pg_trns_grey = -1, pg_trns_r = -1, pg_trns_g, pg_trns_b;
static int pg_f, pg_dw, pg_dh, pg_stride;         /* the shrink factor, what comes out */
static png_u8 *pg_out;
static png_u8 pg_row[PNG_MAX_W * 8 + 8], pg_prev[PNG_MAX_W * 8 + 8];
static int pg_rowlen, pg_rowpos;                  /* this pass's row: its bytes, filled */
static int pg_pass, pg_py, pg_pw, pg_ph;          /* the pass, its row, its size */
static unsigned pg_acc[1024 * 4];                 /* the shrunk row's sums (r g b n) */
static int pg_done;

static const int adam_x0[7] = { 0, 4, 0, 2, 0, 1, 0 }, adam_dx[7] = { 8, 8, 4, 4, 2, 2, 1 };
static const int adam_y0[7] = { 0, 0, 4, 0, 2, 0, 1 }, adam_dy[7] = { 8, 8, 8, 4, 4, 2, 2 };

static unsigned png_be32(const png_u8 *p) { return (unsigned)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }

/* the next pass with something in it (pg_pw, pg_ph); 0 when there's none */
static int png_pass_setup(void)
{
    for (;;) {
        if (!pg_inter) { if (pg_pass > 0) return 0; pg_pw = pg_w; pg_ph = pg_h; }
        else {
            if (pg_pass >= 7) return 0;
            pg_pw = (pg_w - adam_x0[pg_pass] + adam_dx[pg_pass] - 1) / adam_dx[pg_pass];
            pg_ph = (pg_h - adam_y0[pg_pass] + adam_dy[pg_pass] - 1) / adam_dy[pg_pass];
            if (pg_w <= adam_x0[pg_pass]) pg_pw = 0;
            if (pg_h <= adam_y0[pg_pass]) pg_ph = 0;
        }
        if (pg_pw > 0 && pg_ph > 0) {
            int i;
            pg_rowlen = 1 + (pg_pw * pg_chan * pg_depth + 7) / 8;
            pg_rowpos = 0; pg_py = 0;
            for (i = 0; i < pg_rowlen; i++) pg_prev[i] = 0;
            return 1;
        }
        pg_pass++;
        if (!pg_inter) return 0;
    }
}

/* a sample of the row (its index-th, in pg_depth bits) */
static int png_sample(const png_u8 *r, int index)
{
    int d = pg_depth;
    if (d == 8) return r[index];
    if (d == 16) return r[index * 2];                       /* (the high byte) */
    {
        int bit = index * d, v = r[bit >> 3] >> (8 - d - (bit & 7));
        return v & ((1 << d) - 1);
    }
}
/* pixel x of the row -> r, g, b over white */
static void png_pixel(const png_u8 *r, int x, int *R, int *G, int *B)
{
    int a = 255, v, c = x * pg_chan;
    int scale = pg_depth >= 8 ? 1 : 255 / ((1 << pg_depth) - 1);
    switch (pg_ctype) {
    case 0:                                                /* grey */
        v = png_sample(r, c);
        if (pg_trns_grey >= 0 && v == (pg_depth == 16 ? pg_trns_grey >> 8 : pg_trns_grey)) a = 0;
        *R = *G = *B = pg_depth >= 8 ? v : v * scale;
        break;
    case 2:                                                /* RGB */
        *R = png_sample(r, c); *G = png_sample(r, c + 1); *B = png_sample(r, c + 2);
        if (pg_trns_r >= 0 && pg_depth == 8 && *R == pg_trns_r && *G == pg_trns_g && *B == pg_trns_b) a = 0;
        break;
    case 3:                                                /* a palette's */
        v = png_sample(r, c);
        if (v >= pg_npal) v = 0;
        *R = pg_pal[v * 4]; *G = pg_pal[v * 4 + 1]; *B = pg_pal[v * 4 + 2]; a = pg_pal[v * 4 + 3];
        break;
    case 4:                                                /* grey, alpha */
        *R = *G = *B = png_sample(r, c); a = png_sample(r, c + 1);
        break;
    default:                                               /* RGBA */
        *R = png_sample(r, c); *G = png_sample(r, c + 1); *B = png_sample(r, c + 2); a = png_sample(r, c + 3);
    }
    if (a < 255) {                                         /* over white */
        *R = (*R * a + 255 * (255 - a)) / 255;
        *G = (*G * a + 255 * (255 - a)) / 255;
        *B = (*B * a + 255 * (255 - a)) / 255;
    }
}
static void png_put(int dx, int dy, int R, int G, int B)
{
    png_u8 *p;
    if (dx >= pg_dw || dy >= pg_dh) return;
    p = pg_out + 54 + (pg_dh - 1 - dy) * pg_stride + dx * 3;
    p[0] = B; p[1] = G; p[2] = R;
}
static void png_flush_acc(int dy)
{
    int x;
    for (x = 0; x < pg_dw; x++) {
        unsigned *a = pg_acc + x * 4;
        if (a[3]) png_put(x, dy, a[0] / a[3], a[1] / a[3], a[2] / a[3]);
        a[0] = a[1] = a[2] = a[3] = 0;
    }
}
/* a whole row's bytes are in: unfiltered, its pixels placed */
static void png_row_done(void)
{
    int i, n = pg_rowlen - 1, ft = pg_row[0];
    png_u8 *r = pg_row + 1, *p = pg_prev + 1;
    for (i = 0; i < n; i++) {
        int a = i >= pg_bpp ? r[i - pg_bpp] : 0, b = p[i], c = i >= pg_bpp ? p[i - pg_bpp] : 0;
        switch (ft) {
        case 1: r[i] += a; break;
        case 2: r[i] += b; break;
        case 3: r[i] += (a + b) >> 1; break;
        case 4: {
            int pp = a + b - c, pa = pp > a ? pp - a : a - pp, pb = pp > b ? pp - b : b - pp, pc = pp > c ? pp - c : c - pp;
            r[i] += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
            break;
        }
        }
    }
    if (!pg_inter) {
        int y = pg_py, x;
        for (x = 0; x < pg_w; x++) {
            int R, G, B;
            unsigned *a = pg_acc + (x / pg_f) * 4;
            png_pixel(r, x, &R, &G, &B);
            a[0] += R; a[1] += G; a[2] += B; a[3]++;
        }
        if (y % pg_f == pg_f - 1 || y == pg_h - 1) png_flush_acc(y / pg_f);
    } else {
        int y = adam_y0[pg_pass] + pg_py * adam_dy[pg_pass], x;
        if (y % pg_f == 0)
            for (x = 0; x < pg_pw; x++) {
                int fx = adam_x0[pg_pass] + x * adam_dx[pg_pass], R, G, B;
                if (fx % pg_f) continue;
                png_pixel(r, x, &R, &G, &B);
                png_put(fx / pg_f, y / pg_f, R, G, B);
            }
    }
    for (i = 0; i < pg_rowlen; i++) pg_prev[i] = pg_row[i];
    pg_rowpos = 0;
    if (++pg_py >= pg_ph) {
        pg_pass++;
        if (!png_pass_setup()) pg_done = 1;
    }
}
static void png_byte(int c)
{
    if (pg_done) return;
    pg_row[pg_rowpos++] = c;
    if (pg_rowpos == pg_rowlen) png_row_done();
}

/* ---- inflate (RFC 1951), its output to png_byte() ---- */
static const png_u8 *pz_in;
static int pz_n, pz_pos, pz_bit, pz_err;
static png_u8 pz_win[32768];
static int pz_wpos;
struct png_huff { short count[16], sym[288]; };

static int pz_getbit(void)
{
    int b;
    if (pz_pos >= pz_n) { pz_err = 1; return 0; }
    b = pz_in[pz_pos] >> pz_bit & 1;
    if (++pz_bit == 8) { pz_bit = 0; pz_pos++; }
    return b;
}
static int pz_bits(int n) { int v = 0, i; for (i = 0; i < n; i++) v |= pz_getbit() << i; return v; }
static void pz_emit(int c) { pz_win[pz_wpos++ & 32767] = c; png_byte(c); }
static int pz_build(struct png_huff *h, const short *len, int n)
{
    short offs[16];
    int i;
    for (i = 0; i < 16; i++) h->count[i] = 0;
    for (i = 0; i < n; i++) h->count[len[i]]++;
    h->count[0] = 0;
    offs[1] = 0;
    for (i = 1; i < 15; i++) offs[i + 1] = offs[i] + h->count[i];
    for (i = 0; i < n; i++) if (len[i]) h->sym[offs[len[i]]++] = i;
    return 0;
}
static int pz_decode(struct png_huff *h)
{
    int code = 0, first = 0, index = 0, len;
    for (len = 1; len < 16; len++) {
        int count;
        code |= pz_getbit();
        count = h->count[len];
        if (code - count < first) return h->sym[index + (code - first)];
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
        if (pz_err) return -1;
    }
    pz_err = 2;
    return -1;
}
static const short pz_lbase[29] = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
static const short pz_lext[29] = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
static const short pz_dbase[30] = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
static const short pz_dext[30] = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
static struct png_huff pz_lc, pz_dc;

static int pz_codes(void)
{
    for (;;) {
        int s = pz_decode(&pz_lc);
        if (s < 0 || pz_err) return -1;
        if (s < 256) pz_emit(s);
        else if (s == 256) return 0;
        else {
            int len, dist, d;
            s -= 257;
            if (s >= 29) return -1;
            len = pz_lbase[s] + pz_bits(pz_lext[s]);
            d = pz_decode(&pz_dc);
            if (d < 0 || d >= 30) return -1;
            dist = pz_dbase[d] + pz_bits(pz_dext[d]);
            if (dist > pz_wpos) return -1;
            while (len--) pz_emit(pz_win[(pz_wpos - dist) & 32767]);
        }
        if (pg_done) return 0;
    }
}
static int pz_inflate(const png_u8 *src, int n)
{
    int last;
    pz_in = src; pz_n = n; pz_pos = 0; pz_bit = 0; pz_err = 0; pz_wpos = 0;
    do {
        int type;
        last = pz_getbit();
        type = pz_bits(2);
        if (type == 0) {                                   /* stored */
            int len;
            if (pz_bit) { pz_bit = 0; pz_pos++; }
            if (pz_pos + 4 > pz_n) return -1;
            len = pz_in[pz_pos] | pz_in[pz_pos + 1] << 8;
            pz_pos += 4;
            if (pz_pos + len > pz_n) return -1;
            while (len--) pz_emit(pz_in[pz_pos++]);
        } else if (type == 1) {                            /* the fixed codes */
            static short l[320];
            int i;
            for (i = 0; i < 144; i++) l[i] = 8;
            for (; i < 256; i++) l[i] = 9;
            for (; i < 280; i++) l[i] = 7;
            for (; i < 288; i++) l[i] = 8;
            pz_build(&pz_lc, l, 288);
            for (i = 0; i < 30; i++) l[i] = 5;
            pz_build(&pz_dc, l, 30);
            if (pz_codes()) return -1;
        } else if (type == 2) {                            /* codes of its own */
            static const png_u8 order[19] = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
            static short l[320];
            int nlen = pz_bits(5) + 257, ndist = pz_bits(5) + 1, ncode = pz_bits(4) + 4, i, k = 0;
            for (i = 0; i < 19; i++) l[i] = 0;
            for (i = 0; i < ncode; i++) l[order[i]] = pz_bits(3);
            pz_build(&pz_lc, l, 19);
            while (k < nlen + ndist) {
                int s = pz_decode(&pz_lc), rep = 0, v = 0;
                if (s < 0) return -1;
                if (s < 16) { l[k++] = s; continue; }
                if (s == 16) { if (!k) return -1; v = l[k - 1]; rep = 3 + pz_bits(2); }
                else if (s == 17) rep = 3 + pz_bits(3);
                else rep = 11 + pz_bits(7);
                if (k + rep > nlen + ndist) return -1;
                while (rep--) l[k++] = v;
            }
            pz_build(&pz_lc, l, nlen);
            pz_build(&pz_dc, l + nlen, ndist);
            if (pz_codes()) return -1;
        } else return -1;
        if (pz_err) return -1;
    } while (!last && !pg_done);
    return 0;
}

/* ---- the file ---- */
static int png_to_bmp(png_u8 *in, int n, png_u8 *out, int max, int max_w, int max_h)
{
    static const png_u8 sig[8] = { 137, 80, 78, 71, 13, 10, 26, 10 };
    int at = 8, z = 0, i, size;
    if (n < 33) return -1;
    for (i = 0; i < 8; i++) if (in[i] != sig[i]) return -1;
    pg_w = 0; pg_npal = 0; pg_trns_grey = -1; pg_trns_r = -1;
    for (i = 0; i < 256; i++) { pg_pal[i * 4] = pg_pal[i * 4 + 1] = pg_pal[i * 4 + 2] = 0; pg_pal[i * 4 + 3] = 255; }
    /* the chunks: IHDR, PLTE, tRNS read; IDATs gathered at the file's start */
    while (at + 12 <= n) {
        unsigned len = png_be32(in + at);
        const png_u8 *type = in + at + 4, *d = in + at + 8;
        if (len > (unsigned)(n - at - 12)) return -2;
        if (type[0] == 'I' && type[1] == 'H' && type[2] == 'D' && type[3] == 'R') {
            pg_w = png_be32(d); pg_h = png_be32(d + 4);
            pg_depth = d[8]; pg_ctype = d[9]; pg_inter = d[12];
            if (d[10] || d[11] || pg_inter > 1) return -3;
        } else if (type[0] == 'P' && type[1] == 'L' && type[2] == 'T' && type[3] == 'E') {
            pg_npal = len / 3 > 256 ? 256 : len / 3;
            for (i = 0; i < pg_npal; i++) { pg_pal[i * 4] = d[i * 3]; pg_pal[i * 4 + 1] = d[i * 3 + 1]; pg_pal[i * 4 + 2] = d[i * 3 + 2]; }
        } else if (type[0] == 't' && type[1] == 'R' && type[2] == 'N' && type[3] == 'S') {
            if (pg_ctype == 3) for (i = 0; i < (int)len && i < 256; i++) pg_pal[i * 4 + 3] = d[i];
            else if (pg_ctype == 0 && len >= 2) pg_trns_grey = d[0] << 8 | d[1];
            else if (pg_ctype == 2 && len >= 6) { pg_trns_r = d[1]; pg_trns_g = d[3]; pg_trns_b = d[5]; }
        } else if (type[0] == 'I' && type[1] == 'D' && type[2] == 'A' && type[3] == 'T') {
            for (i = 0; i < (int)len; i++) in[z++] = d[i];            /* (z <= at + 8: safe) */
        } else if (type[0] == 'I' && type[1] == 'E' && type[2] == 'N' && type[3] == 'D') break;
        at += 12 + len;
    }
    if (!pg_w || pg_w > PNG_MAX_W || pg_h <= 0 || pg_h > 32768 || z < 3) return -3;
    switch (pg_ctype) {
    case 0: pg_chan = 1; break;
    case 2: pg_chan = 3; break;
    case 3: pg_chan = 1; break;
    case 4: pg_chan = 2; break;
    case 6: pg_chan = 4; break;
    default: return -3;
    }
    if (pg_depth != 1 && pg_depth != 2 && pg_depth != 4 && pg_depth != 8 && pg_depth != 16) return -3;
    pg_bpp = pg_chan * pg_depth / 8;
    if (pg_bpp < 1) pg_bpp = 1;
    /* how much to shrink it */
    if (max_w > 1024) max_w = 1024;
    pg_f = 1;
    while ((pg_w + pg_f - 1) / pg_f > max_w || (pg_h + pg_f - 1) / pg_f > max_h) pg_f++;
    pg_dw = (pg_w + pg_f - 1) / pg_f;
    pg_dh = (pg_h + pg_f - 1) / pg_f;
    pg_stride = (pg_dw * 3 + 3) & ~3;
    size = 54 + pg_stride * pg_dh;
    if (size > max) return -4;
    pg_out = out;
    for (i = 0; i < size; i++) out[i] = 255;               /* (white where nothing comes) */
    /* the header: BITMAPFILEHEADER, BITMAPINFOHEADER; 24 bits, bottom-up */
    for (i = 0; i < 54; i++) out[i] = 0;
    out[0] = 'B'; out[1] = 'M';
    out[2] = size; out[3] = size >> 8; out[4] = size >> 16; out[5] = size >> 24;
    out[10] = 54; out[14] = 40;
    out[18] = pg_dw; out[19] = pg_dw >> 8;
    out[22] = pg_dh; out[23] = pg_dh >> 8;
    out[26] = 1; out[28] = 24;
    for (i = 0; i < pg_dw * 4; i++) pg_acc[i] = 0;
    pg_pass = 0; pg_done = 0;
    if (!png_pass_setup()) return -3;
    /* the zlib wrapper: 2 bytes, then deflate */
    if ((in[0] & 15) != 8) return -3;
    if (pz_inflate(in + 2, z - 2) && !pg_done) return -5;
    return size;
}

#endif
