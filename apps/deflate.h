/* deflate.h - compression (deflate, RFC 1951) and CRC-32, for LexOS
 * programs in C: zip.c's, and Paint's for .PNG.
 *
 *   crc_init();  unsigned c = crc32(p, n);
 *   int n = deflate(in, len, out, cap);     -> the compressed bytes, or -1
 *   (or a piece at a time: deflate_start, deflate_more, deflate_taken)
 * Its tables (384KB) are malloc'd on the first use; deflate_free()
 * gives them back.
 *
 * LZ77 over hash chains of the last 32KB, then each block's own
 * (dynamic) Huffman codes. */
#ifndef DEFLATE_H
#define DEFLATE_H
#include "lexos.h"

/* ============================================================
 * CRC-32
 * ============================================================ */
static unsigned crc_table[256];
static void crc_init(void)
{
    unsigned c, n, k;
    for (n = 0; n < 256; n++) {
        c = n;
        for (k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
        crc_table[n] = c;
    }
}
static __attribute__((unused)) unsigned crc32(const unsigned char *p, int n)
{
    unsigned c = 0xFFFFFFFF;
    while (n--) c = crc_table[(c ^ *p++) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFF;
}

/* ============================================================
 * deflate: LZ77 (hash chains over the last 32KB), then each block's
 * own (dynamic) Huffman codes
 * ============================================================ */
static unsigned char *df_out;
static int df_outn, df_outcap;
static unsigned df_bitbuf;
static int df_bitcnt;

static void df_put_bits(unsigned v, int n)         /* LSB first */
{
    df_bitbuf |= v << df_bitcnt;
    df_bitcnt += n;
    while (df_bitcnt >= 8) {
        if (df_outn < df_outcap) df_out[df_outn] = df_bitbuf & 0xFF;
        df_outn++;
        df_bitbuf >>= 8;
        df_bitcnt -= 8;
    }
}
static void df_put_code(unsigned code, int len)    /* a Huffman code: MSB first */
{
    unsigned r = 0;
    int i;
    for (i = 0; i < len; i++) r |= ((code >> i) & 1) << (len - 1 - i);
    df_put_bits(r, len);
}
static const unsigned short df_len_base[29] = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
static const unsigned char df_len_extra[29] = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
static const unsigned short df_dist_base[30] = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
static const unsigned char df_dist_extra[30] = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

#define WSIZE 32768
#define HBITS 15
static int *df_head, *df_prev;                  /* (malloc'd by deflate_start) */

static int df_hash3(const unsigned char *p) { return ((p[0] << 10) ^ (p[1] << 5) ^ p[2]) & ((1 << HBITS) - 1); }

/* LZ77's output, a block at a time: a literal (0-255), or a match
 * (1 << 31 | length << 16 | distance) */
#define TOKENS 32768
static unsigned *df_tok;
static int df_ntok;

/* freq[0..n) -> len[0..n): Huffman code lengths, none over limit */
static void df_lengths(const unsigned *freq, int n, unsigned char *len, int limit)
{
    static unsigned w[640];
    static int parent[640], alive[640];
    unsigned f[320];
    int i, nodes, used, tries;
    for (i = 0; i < n; i++) f[i] = freq[i];
    for (tries = 0; tries < 20; tries++) {
        int maxl = 0;
        nodes = n;
        used = 0;
        for (i = 0; i < n; i++) { w[i] = f[i]; parent[i] = -1; alive[i] = f[i] > 0; used += alive[i]; len[i] = 0; }
        if (used == 0) return;
        if (used == 1) { for (i = 0; i < n; i++) if (f[i]) len[i] = 1; return; }
        for (;;) {                                /* the two lightest, joined */
            int a = -1, b = -1;
            for (i = 0; i < nodes; i++) {
                if (!alive[i]) continue;
                if (a < 0 || w[i] < w[a]) { b = a; a = i; }
                else if (b < 0 || w[i] < w[b]) b = i;
            }
            if (b < 0) break;
            w[nodes] = w[a] + w[b];
            parent[nodes] = -1;
            alive[nodes] = 1;
            alive[a] = alive[b] = 0;
            parent[a] = parent[b] = nodes;
            nodes++;
        }
        for (i = 0; i < n; i++) {
            int d = 0, k = i;
            if (!f[i]) continue;
            while (parent[k] >= 0) { k = parent[k]; d++; }
            len[i] = d;
            if (d > maxl) maxl = d;
        }
        if (maxl <= limit) return;
        for (i = 0; i < n; i++) if (f[i]) f[i] = (f[i] >> 1) | 1;   /* flatter: again */
    }
}
/* lengths -> canonical codes */
static void df_canon(const unsigned char *len, int n, unsigned short *code)
{
    int count[16] = { 0 }, next[16], i, c = 0;
    for (i = 0; i < n; i++) count[len[i]]++;
    count[0] = 0;
    for (i = 1; i < 16; i++) { c = (c + count[i - 1]) << 1; next[i] = c; }
    for (i = 0; i < n; i++) if (len[i]) code[i] = next[len[i]]++;
}
static int df_len_sym(int l) { int i; for (i = 28; df_len_base[i] > l; i--); return i; }
static int df_dist_sym(int d) { int i; for (i = 29; df_dist_base[i] > d; i--); return i; }

/* the tokens so far: a block with its own (dynamic) Huffman codes */
static void df_flush_block(int last)
{
    static const unsigned char order[19] = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    unsigned lf[286], df[30], cf[19];
    unsigned char ll[286], dl[30], cl[19], all[316];
    unsigned short lc[286], dc[30], cc[19];
    int rle[316], rlex[316], nr = 0, i, hlit, hdist, hclen, n;
    memset(lf, 0, sizeof lf); memset(df, 0, sizeof df); memset(cf, 0, sizeof cf);
    for (i = 0; i < df_ntok; i++) {
        unsigned t = df_tok[i];
        if (t >> 31) { lf[257 + df_len_sym(t >> 16 & 0x7FFF)]++; df[df_dist_sym(t & 0xFFFF)]++; }
        else lf[t]++;
    }
    lf[256] = 1;
    df_lengths(lf, 286, ll, 15);
    df_lengths(df, 30, dl, 15);
    for (hlit = 286; hlit > 257 && !ll[hlit - 1]; hlit--);
    for (hdist = 30; hdist > 1 && !dl[hdist - 1]; hdist--);
    if (!dl[0] && hdist == 1) dl[0] = 1;      /* (one code, never used) */
    memcpy(all, ll, hlit);
    memcpy(all + hlit, dl, hdist);
    n = hlit + hdist;
    for (i = 0; i < n; ) {                     /* the lengths, run-length coded */
        int r = 1;
        while (i + r < n && all[i + r] == all[i]) r++;
        if (all[i] == 0 && r >= 3) {
            if (r > 138) r = 138;
            if (r >= 11) { rle[nr] = 18; rlex[nr++] = r - 11; }
            else { rle[nr] = 17; rlex[nr++] = r - 3; }
            i += r;
        } else if (r >= 4) {
            rle[nr] = all[i]; rlex[nr++] = 0;
            r--;
            if (r > 6) r = 6;
            rle[nr] = 16; rlex[nr++] = r - 3;
            i += r + 1;
        } else { rle[nr] = all[i]; rlex[nr++] = 0; i++; }
    }
    for (i = 0; i < nr; i++) cf[rle[i]]++;
    df_lengths(cf, 19, cl, 7);
    for (hclen = 19; hclen > 4 && !cl[order[hclen - 1]]; hclen--);
    df_canon(ll, 286, lc);
    df_canon(dl, 30, dc);
    df_canon(cl, 19, cc);
    df_put_bits(last, 1);
    df_put_bits(2, 2);
    df_put_bits(hlit - 257, 5);
    df_put_bits(hdist - 1, 5);
    df_put_bits(hclen - 4, 4);
    for (i = 0; i < hclen; i++) df_put_bits(cl[order[i]], 3);
    for (i = 0; i < nr; i++) {
        df_put_code(cc[rle[i]], cl[rle[i]]);
        if (rle[i] == 16) df_put_bits(rlex[i], 2);
        else if (rle[i] == 17) df_put_bits(rlex[i], 3);
        else if (rle[i] == 18) df_put_bits(rlex[i], 7);
    }
    for (i = 0; i < df_ntok; i++) {
        unsigned t = df_tok[i];
        if (t >> 31) {
            int l = t >> 16 & 0x7FFF, d = t & 0xFFFF, s2 = df_len_sym(l), ds = df_dist_sym(d);
            df_put_code(lc[257 + s2], ll[257 + s2]);
            if (df_len_extra[s2]) df_put_bits(l - df_len_base[s2], df_len_extra[s2]);
            df_put_code(dc[ds], dl[ds]);
            if (df_dist_extra[ds]) df_put_bits(d - df_dist_base[ds], df_dist_extra[ds]);
        } else df_put_code(lc[t], ll[t]);
    }
    df_put_code(lc[256], ll[256]);
    df_ntok = 0;
}

/* a stream, a piece at a time (matches only within each piece):
 * deflate_start(out, cap); deflate_more(piece, n, last) -> the bytes in
 * out so far (-1: out's full) - they can be taken (written somewhere)
 * and deflate_taken() lets out be filled again from its start */
static int df_final;
/* its tables (384KB) freed, until the next deflate_start */
static __attribute__((unused)) void deflate_free(void)
{
    free(df_head); free(df_prev); free(df_tok);
    df_head = df_prev = 0; df_tok = 0;
}
static int deflate_start(unsigned char *o, int cap)       /* -> 0, or -1: no memory */
{
    if (!df_head || !df_prev || !df_tok) {
        deflate_free();
        df_head = malloc((1 << HBITS) * sizeof *df_head);
        df_prev = malloc(WSIZE * sizeof *df_prev);
        df_tok = malloc(TOKENS * sizeof *df_tok);
        if (!df_head || !df_prev || !df_tok) { deflate_free(); return -1; }
    }
    df_out = o; df_outn = 0; df_outcap = cap; df_bitbuf = 0; df_bitcnt = 0; df_ntok = 0; df_final = 0;
    return 0;
}
static __attribute__((unused)) void deflate_taken(void) { df_outn = 0; }
static int deflate_more(const unsigned char *in, int n, int last)
{
    int i = 0, k;
    for (k = 0; k < (1 << HBITS); k++) df_head[k] = -1;
    while (i < n) {
        int best = 0, bdist = 0;
        if (i + 2 < n) {
            int h = df_hash3(in + i), c = df_head[h], chain = 96;
            while (c >= 0 && i - c <= WSIZE && chain--) {
                if (in[c + best] == in[i + best] && in[c] == in[i]) {
                    int l = 0, max = n - i < 258 ? n - i : 258;
                    while (l < max && in[c + l] == in[i + l]) l++;
                    if (l > best) { best = l; bdist = i - c; if (l == max) break; }
                }
                c = df_prev[c & (WSIZE - 1)];
            }
            df_prev[i & (WSIZE - 1)] = df_head[h];
            df_head[h] = i;
        }
        if (best >= 3) {
            df_tok[df_ntok++] = 1u << 31 | best << 16 | bdist;
            for (k = 1; k < best; k++) {            /* the rest into the chains */
                int j = i + k;
                if (j + 2 < n) { int h = df_hash3(in + j); df_prev[j & (WSIZE - 1)] = df_head[h]; df_head[h] = j; }
            }
            i += best;
        } else df_tok[df_ntok++] = in[i++];
        if (df_ntok == TOKENS) { df_flush_block(last && i >= n); if (last && i >= n) df_final = 1; }
        if (df_outn > df_outcap) return -1;
    }
    if (df_ntok) { df_flush_block(last); if (last) df_final = 1; }
    if (last && !df_final) { df_flush_block(1); df_final = 1; }   /* (an empty last block) */
    if (last) df_put_bits(0, 7);                 /* (the last byte out) */
    return df_outn > df_outcap ? -1 : df_outn;
}

/* in[0..n) -> out (deflate); its length, or -1 if it didn't fit in cap */
static __attribute__((unused)) int deflate(const unsigned char *in, int n, unsigned char *o, int cap)
{
    if (deflate_start(o, cap)) return -1;
    return deflate_more(in, n, 1);
}

#endif
