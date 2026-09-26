/* zip.c - ZIP archives: packing and unpacking.
 *
 *   zip.app ARCHIVE.ZIP NAME...        pack files and folders into it
 *   zip.app -x ARCHIVE.ZIP [FOLDER]    unpack it (into a folder named
 *                                      after it, next to it, if none)
 *   zip.app -l ARCHIVE.ZIP             what's in it
 *   -q (first): quiet - only a line at the top of the desktop at the
 *   end (Files' "Compress to ZIP" and "Extract here" run it that way)
 *
 * The files are compressed with deflate (LZ77 over a 32KB window, then
 * Huffman codes made for each block) - or stored, if that doesn't make them smaller - with
 * CRC-32s, so any unzip can open them. Unpacking reads deflate whole
 * (stored, fixed and dynamic blocks): archives from other computers
 * open too. Their names become LexOS names: capitals, 15 characters. */
#include "lexos.h"

#define MAX_ENTRIES 512
#define PATH_MAX 96

static int quiet;
static char msg[80];

static void say(const char *s) { if (!quiet) puts(s); }
static int upper(int c) { return c >= 'a' && c <= 'z' ? c - 32 : c; }
static void copy(char *d, const char *s, int n) { int i = 0; while (s[i] && i < n - 1) { d[i] = s[i]; i++; } d[i] = 0; }
static void append(char *d, const char *s, int n) { int l = strlen(d); copy(d + l, s, n - l); }
static void append_num(char *d, int v, int n)
{
    char b[12]; int i = 11; unsigned u = v;
    b[i] = 0;
    do { b[--i] = '0' + u % 10; u /= 10; } while (u);
    append(d, b + i, n);
}
static void finish(const char *s)            /* the last word */
{
    if (quiet) notify(s);
    else { puts(s); putchar('\n'); }
}

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
static unsigned crc32(const unsigned char *p, int n)
{
    unsigned c = 0xFFFFFFFF;
    while (n--) c = crc_table[(c ^ *p++) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFF;
}

/* ============================================================
 * deflate: LZ77 (hash chains over the last 32KB), then each block's
 * own (dynamic) Huffman codes
 * ============================================================ */
static unsigned char *out;
static int outn, outcap;
static unsigned bitbuf;
static int bitcnt;

static void put_bits(unsigned v, int n)         /* LSB first */
{
    bitbuf |= v << bitcnt;
    bitcnt += n;
    while (bitcnt >= 8) {
        if (outn < outcap) out[outn] = bitbuf & 0xFF;
        outn++;
        bitbuf >>= 8;
        bitcnt -= 8;
    }
}
static void put_code(unsigned code, int len)    /* a Huffman code: MSB first */
{
    unsigned r = 0;
    int i;
    for (i = 0; i < len; i++) r |= ((code >> i) & 1) << (len - 1 - i);
    put_bits(r, len);
}
static const unsigned short len_base[29] = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
static const unsigned char len_extra[29] = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
static const unsigned short dist_base[30] = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
static const unsigned char dist_extra[30] = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

#define WSIZE 32768
#define HBITS 15
static int head[1 << HBITS], prev[WSIZE];

static int hash3(const unsigned char *p) { return ((p[0] << 10) ^ (p[1] << 5) ^ p[2]) & ((1 << HBITS) - 1); }

/* LZ77's output, a block at a time: a literal (0-255), or a match
 * (1 << 31 | length << 16 | distance) */
#define TOKENS 32768
static unsigned tok[TOKENS];
static int ntok;

/* freq[0..n) -> len[0..n): Huffman code lengths, none over limit */
static void lengths(const unsigned *freq, int n, unsigned char *len, int limit)
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
static void canon(const unsigned char *len, int n, unsigned short *code)
{
    int count[16] = { 0 }, next[16], i, c = 0;
    for (i = 0; i < n; i++) count[len[i]]++;
    count[0] = 0;
    for (i = 1; i < 16; i++) { c = (c + count[i - 1]) << 1; next[i] = c; }
    for (i = 0; i < n; i++) if (len[i]) code[i] = next[len[i]]++;
}
static int len_sym(int l) { int i; for (i = 28; len_base[i] > l; i--); return i; }
static int dist_sym(int d) { int i; for (i = 29; dist_base[i] > d; i--); return i; }

/* the tokens so far: a block with its own (dynamic) Huffman codes */
static void flush_block(int last)
{
    static const unsigned char order[19] = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    unsigned lf[286], df[30], cf[19];
    unsigned char ll[286], dl[30], cl[19], all[316];
    unsigned short lc[286], dc[30], cc[19];
    int rle[316], rlex[316], nr = 0, i, hlit, hdist, hclen, n;
    memset(lf, 0, sizeof lf); memset(df, 0, sizeof df); memset(cf, 0, sizeof cf);
    for (i = 0; i < ntok; i++) {
        unsigned t = tok[i];
        if (t >> 31) { lf[257 + len_sym(t >> 16 & 0x7FFF)]++; df[dist_sym(t & 0xFFFF)]++; }
        else lf[t]++;
    }
    lf[256] = 1;
    lengths(lf, 286, ll, 15);
    lengths(df, 30, dl, 15);
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
    lengths(cf, 19, cl, 7);
    for (hclen = 19; hclen > 4 && !cl[order[hclen - 1]]; hclen--);
    canon(ll, 286, lc);
    canon(dl, 30, dc);
    canon(cl, 19, cc);
    put_bits(last, 1);
    put_bits(2, 2);
    put_bits(hlit - 257, 5);
    put_bits(hdist - 1, 5);
    put_bits(hclen - 4, 4);
    for (i = 0; i < hclen; i++) put_bits(cl[order[i]], 3);
    for (i = 0; i < nr; i++) {
        put_code(cc[rle[i]], cl[rle[i]]);
        if (rle[i] == 16) put_bits(rlex[i], 2);
        else if (rle[i] == 17) put_bits(rlex[i], 3);
        else if (rle[i] == 18) put_bits(rlex[i], 7);
    }
    for (i = 0; i < ntok; i++) {
        unsigned t = tok[i];
        if (t >> 31) {
            int l = t >> 16 & 0x7FFF, d = t & 0xFFFF, s2 = len_sym(l), ds = dist_sym(d);
            put_code(lc[257 + s2], ll[257 + s2]);
            if (len_extra[s2]) put_bits(l - len_base[s2], len_extra[s2]);
            put_code(dc[ds], dl[ds]);
            if (dist_extra[ds]) put_bits(d - dist_base[ds], dist_extra[ds]);
        } else put_code(lc[t], ll[t]);
    }
    put_code(lc[256], ll[256]);
    ntok = 0;
}

/* in[0..n) -> out (deflate); its length, or -1 if it didn't fit in cap */
static int deflate(const unsigned char *in, int n, unsigned char *o, int cap)
{
    int i = 0, k;
    out = o; outn = 0; outcap = cap; bitbuf = 0; bitcnt = 0; ntok = 0;
    for (k = 0; k < (1 << HBITS); k++) head[k] = -1;
    while (i < n) {
        int best = 0, bdist = 0;
        if (i + 2 < n) {
            int h = hash3(in + i), c = head[h], chain = 96;
            while (c >= 0 && i - c <= WSIZE && chain--) {
                if (in[c + best] == in[i + best] && in[c] == in[i]) {
                    int l = 0, max = n - i < 258 ? n - i : 258;
                    while (l < max && in[c + l] == in[i + l]) l++;
                    if (l > best) { best = l; bdist = i - c; if (l == max) break; }
                }
                c = prev[c & (WSIZE - 1)];
            }
            prev[i & (WSIZE - 1)] = head[h];
            head[h] = i;
        }
        if (best >= 3) {
            tok[ntok++] = 1u << 31 | best << 16 | bdist;
            for (k = 1; k < best; k++) {            /* the rest into the chains */
                int j = i + k;
                if (j + 2 < n) { int h = hash3(in + j); prev[j & (WSIZE - 1)] = head[h]; head[h] = j; }
            }
            i += best;
        } else tok[ntok++] = in[i++];
        if (ntok == TOKENS) flush_block(i >= n);
        if (outn > cap) return -1;
    }
    if (ntok || !n) flush_block(1);
    else if (outn == 0) flush_block(1);
    put_bits(0, 7);                             /* (the last byte out) */
    return outn > cap ? -1 : outn;
}

/* ============================================================
 * inflate (as zlib's "puff": stored, fixed, dynamic)
 * ============================================================ */
static const unsigned char *in_p;
static int in_n, in_pos, in_bit;
static unsigned char *dst;
static int dst_n, dst_cap, inf_err;

static int get_bit(void)
{
    int b;
    if (in_pos >= in_n) { inf_err = 1; return 0; }
    b = (in_p[in_pos] >> in_bit) & 1;
    if (++in_bit == 8) { in_bit = 0; in_pos++; }
    return b;
}
static int get_bits(int n)
{
    int v = 0, i;
    for (i = 0; i < n; i++) v |= get_bit() << i;
    return v;
}
struct huff { short count[16], symbol[320]; };
static int build(struct huff *h, const short *len, int n)
{
    short offs[16];
    int i;
    for (i = 0; i < 16; i++) h->count[i] = 0;
    for (i = 0; i < n; i++) h->count[len[i]]++;
    offs[1] = 0;
    for (i = 1; i < 15; i++) offs[i + 1] = offs[i] + h->count[i];
    for (i = 0; i < n; i++) if (len[i]) h->symbol[offs[len[i]]++] = i;
    return 0;
}
static int decode(struct huff *h)
{
    int code = 0, first = 0, index = 0, len;
    for (len = 1; len < 16; len++) {
        int count;
        code |= get_bit();
        count = h->count[len];
        if (code - count < first) return h->symbol[index + (code - first)];
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
        if (inf_err) return -1;
    }
    inf_err = 1;
    return -1;
}
static void emit(int c) { if (dst_n < dst_cap) dst[dst_n++] = c; else inf_err = 2; }
static int codes(struct huff *lc, struct huff *dc)
{
    int sym;
    for (;;) {
        sym = decode(lc);
        if (inf_err) return -1;
        if (sym < 256) emit(sym);
        else if (sym == 256) return 0;
        else {
            int l, d, dsym;
            sym -= 257;
            if (sym >= 29) { inf_err = 1; return -1; }
            l = len_base[sym] + get_bits(len_extra[sym]);
            dsym = decode(dc);
            if (dsym < 0 || dsym >= 30) { inf_err = 1; return -1; }
            d = dist_base[dsym] + get_bits(dist_extra[dsym]);
            if (d > dst_n) { inf_err = 1; return -1; }
            while (l--) { emit(dst[dst_n - d]); if (inf_err) return -1; }
        }
    }
}
static int inflate(const unsigned char *src, int n, unsigned char *d, int cap)
{
    int last;
    static struct huff lc, dc;
    in_p = src; in_n = n; in_pos = 0; in_bit = 0;
    dst = d; dst_n = 0; dst_cap = cap; inf_err = 0;
    do {
        int type;
        last = get_bit();
        type = get_bits(2);
        if (type == 0) {                            /* stored */
            int len;
            if (in_bit) { in_bit = 0; in_pos++; }
            if (in_pos + 4 > in_n) return -1;
            len = in_p[in_pos] | in_p[in_pos + 1] << 8;
            in_pos += 4;
            if (in_pos + len > in_n) return -1;
            while (len--) emit(in_p[in_pos++]);
        } else if (type == 1) {                     /* fixed */
            short len[320];
            int i;
            for (i = 0; i < 144; i++) len[i] = 8;
            for (; i < 256; i++) len[i] = 9;
            for (; i < 280; i++) len[i] = 7;
            for (; i < 288; i++) len[i] = 8;
            build(&lc, len, 288);
            for (i = 0; i < 30; i++) len[i] = 5;
            build(&dc, len, 30);
            codes(&lc, &dc);
        } else if (type == 2) {                     /* dynamic */
            static const unsigned char order[19] = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
            short len[320];
            int nlen = get_bits(5) + 257, ndist = get_bits(5) + 1, ncode = get_bits(4) + 4, i;
            if (nlen > 286 || ndist > 30) return -1;
            for (i = 0; i < 19; i++) len[order[i]] = i < ncode ? get_bits(3) : 0;
            build(&lc, len, 19);
            for (i = 0; i < nlen + ndist; ) {
                int sym = decode(&lc), rep, v = 0;
                if (sym < 0) return -1;
                if (sym < 16) { len[i++] = sym; continue; }
                if (sym == 16) { if (!i) return -1; v = len[i - 1]; rep = 3 + get_bits(2); }
                else if (sym == 17) rep = 3 + get_bits(3);
                else rep = 11 + get_bits(7);
                if (i + rep > nlen + ndist) return -1;
                while (rep--) len[i++] = v;
            }
            build(&lc, len, nlen);
            build(&dc, len + nlen, ndist);
            codes(&lc, &dc);
        } else return -1;
        if (inf_err) return -1;
    } while (!last);
    return dst_n;
}

/* ============================================================
 * little-endian fields
 * ============================================================ */
static unsigned rd16(const unsigned char *p) { return p[0] | p[1] << 8; }
static unsigned rd32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (unsigned)p[3] << 24; }
static void wr16(unsigned char *p, unsigned v) { p[0] = v; p[1] = v >> 8; }
static void wr32(unsigned char *p, unsigned v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

/* ============================================================
 * packing
 * ============================================================ */
struct entry {
    char name[PATH_MAX];
    unsigned crc, csize, usize, offset;
    unsigned short method, time, date;
    int dir;
};
static struct entry *ents;
static int nents, zfd, zpos, nfiles, ztotal_in, bad;
static char zname[PATH_MAX];

static void dos_time(const unsigned char *t, unsigned short *tm, unsigned short *dt)
{
    if (!t[1]) { *tm = 0; *dt = (2026 - 1980) << 9 | 1 << 5 | 1; return; }
    *dt = (t[0] + 2000 - 1980) << 9 | t[1] << 5 | t[2];
    *tm = t[3] << 11 | t[4] << 5;
}

static void zwrite(const void *p, int n)
{
    if (n > 0 && fwrite(zfd, p, n) != n) bad = 1;
    zpos += n;
}

static void local_header(struct entry *e)
{
    unsigned char h[30];
    int nl = strlen(e->name);
    wr32(h, 0x04034b50); wr16(h + 4, 20); wr16(h + 6, 0); wr16(h + 8, e->method);
    wr16(h + 10, e->time); wr16(h + 12, e->date); wr32(h + 14, e->crc);
    wr32(h + 18, e->csize); wr32(h + 22, e->usize); wr16(h + 26, nl); wr16(h + 28, 0);
    e->offset = zpos;
    zwrite(h, 30);
    zwrite(e->name, nl);
}

static void add_file(const char *path, const char *name, const unsigned char *tm)
{
    int fd = open(path, O_READ), n;
    unsigned char *buf, *cbuf;
    struct entry *e;
    if (fd < 0) { say("  can't read "); say(path); say("\n"); return; }
    if (nents >= MAX_ENTRIES) { close(fd); return; }
    n = fsize(fd);
    buf = malloc(n + 1);
    if (!buf) { close(fd); say("  too big: "); say(path); say("\n"); bad = 1; return; }
    n = read(fd, buf, n);
    close(fd);
    if (n < 0) n = 0;
    e = &ents[nents++];
    copy(e->name, name, PATH_MAX);
    e->usize = n;
    e->crc = crc32(buf, n);
    dos_time(tm, &e->time, &e->date);
    e->dir = 0;
    cbuf = n > 16 ? malloc(n) : 0;
    e->method = 0;
    e->csize = n;
    if (cbuf) {
        int c = deflate(buf, n, cbuf, n - 1);
        if (c > 0 && c < n) { e->method = 8; e->csize = c; }
    }
    local_header(e);
    zwrite(e->method ? cbuf : buf, e->csize);
    ztotal_in += n;
    nfiles++;
    if (!quiet) {
        puts("  "); puts(name); puts("  "); print_int(n);
        if (e->method) { puts(" -> "); print_int(e->csize); }
        puts(" bytes\n");
    }
    free(cbuf);
    free(buf);
}

static void add_dir(const char *path, const char *name, const unsigned char *tm, int depth)
{
    struct lx_dirent d;
    struct entry *e;
    int i;
    if (nents >= MAX_ENTRIES || depth > 8) return;
    e = &ents[nents++];
    copy(e->name, name, PATH_MAX);
    append(e->name, "/", PATH_MAX);
    e->usize = e->csize = e->crc = 0;
    e->method = 0;
    e->dir = 1;
    dos_time(tm, &e->time, &e->date);
    local_header(e);
    for (i = 0; readdir(path, i, &d) == 0; i++) {
        char p[PATH_MAX], n2[PATH_MAX];
        copy(p, path, PATH_MAX); append(p, "/", PATH_MAX); append(p, d.name, PATH_MAX);
        copy(n2, name, PATH_MAX); append(n2, "/", PATH_MAX); append(n2, d.name, PATH_MAX);
        if (d.type == LX_DIR) add_dir(p, n2, d.time, depth + 1);
        else add_file(p, n2, d.time);
    }
}

/* a name as given ("SITE", "/DEMOS/QUIZ.HG") -> what it is */
static int stat_of(const char *path, struct lx_dirent *out)
{
    char dir[PATH_MAX];
    const char *base = path, *s;
    int i;
    for (s = path; *s; s++) if (*s == '/') base = s + 1;
    if (base == path) dir[0] = 0;
    else { int l = base - path - 1; copy(dir, path, l > 0 ? l + 1 : 2); if (!l) copy(dir, "/", 2); }
    for (i = 0; readdir(dir, i, out) == 0; i++) {
        int k;
        for (k = 0; base[k] && upper(base[k]) == out->name[k]; k++);
        if (!base[k] && !out->name[k]) return 0;
    }
    return -1;
}

static int pack(const char *archive, char **names, int n)
{
    int i, cdstart;
    unsigned char h[46];
    ents = malloc(sizeof(struct entry) * MAX_ENTRIES);
    if (!ents) return 1;
    copy(zname, archive, PATH_MAX);
    for (i = 0; zname[i]; i++) zname[i] = upper(zname[i]);
    zfd = open(zname, O_WRITE);
    if (zfd < 0) { finish("zip: can't write the archive there"); return 1; }
    say("Packing into "); say(zname); say("\n");
    for (i = 0; i < n; i++) {
        struct lx_dirent d;
        char nm[PATH_MAX];
        const char *s = names[i];
        int k;
        while (*s == '/') s++;                  /* names in it: without the leading / */
        copy(nm, s, PATH_MAX);
        for (k = 0; nm[k]; k++) nm[k] = upper(nm[k]);
        if (stat_of(names[i], &d) < 0) { say("  not found: "); say(names[i]); say("\n"); continue; }
        if (!strcmp(d.name, zname) || !strcmp(nm, zname)) continue;   /* (not itself) */
        if (d.type == LX_DIR) add_dir(names[i], nm, d.time, 0);
        else add_file(names[i], nm, d.time);
    }
    cdstart = zpos;
    for (i = 0; i < nents; i++) {              /* the central directory */
        struct entry *e = &ents[i];
        int nl = strlen(e->name);
        wr32(h, 0x02014b50); wr16(h + 4, 20); wr16(h + 6, 20); wr16(h + 8, 0);
        wr16(h + 10, e->method); wr16(h + 12, e->time); wr16(h + 14, e->date);
        wr32(h + 16, e->crc); wr32(h + 20, e->csize); wr32(h + 24, e->usize);
        wr16(h + 28, nl); wr16(h + 30, 0); wr16(h + 32, 0); wr16(h + 34, 0);
        wr16(h + 36, 0); wr32(h + 38, e->dir ? 0x10 : 0); wr32(h + 42, e->offset);
        zwrite(h, 46);
        zwrite(e->name, nl);
    }
    wr32(h, 0x06054b50); wr16(h + 4, 0); wr16(h + 6, 0); wr16(h + 8, nents); wr16(h + 10, nents);
    wr32(h + 12, zpos - cdstart); wr32(h + 16, cdstart); wr16(h + 20, 0);
    zwrite(h, 22);
    close(zfd);
    if (bad) { finish("zip: not all of it could be written (the disk full?)"); return 1; }
    copy(msg, "Packed ", sizeof msg);
    append_num(msg, nfiles, sizeof msg);
    append(msg, nfiles == 1 ? " file into " : " files into ", sizeof msg);
    append(msg, zname, sizeof msg);
    if (ztotal_in) {
        append(msg, " (", sizeof msg);
        append_num(msg, zpos * 100 / ztotal_in, sizeof msg);
        append(msg, "%)", sizeof msg);
    }
    finish(msg);
    return 0;
}

/* ============================================================
 * unpacking
 * ============================================================ */
static unsigned char *zip;
static int zipn;

static int load_zip(const char *name)
{
    int fd = open(name, O_READ);
    if (fd < 0) { finish("zip: there's no such archive"); return -1; }
    zipn = fsize(fd);
    zip = malloc(zipn + 1);
    if (!zip) { close(fd); finish("zip: the archive is too big for memory"); return -1; }
    zipn = read(fd, zip, zipn);
    close(fd);
    return 0;
}
/* -> the central directory's start, its count; -1 if it's not a ZIP */
static int find_cd(int *count)
{
    int i;
    for (i = zipn - 22; i >= 0 && i >= zipn - 22 - 65535; i--)
        if (rd32(zip + i) == 0x06054b50) {
            *count = rd16(zip + i + 10);
            return rd32(zip + i + 16);
        }
    return -1;
}
/* a name from the archive -> a LexOS one: capitals, each part at most
 * 15 characters (the extension kept), nothing a name can't have */
static void lexos_name(const char *s, int n, char *outp)
{
    int o = 0;
    while (n > 0) {
        char part[64];
        int k = 0, dot = -1, i;
        while (n > 0 && *s != '/' && *s != '\\') { if (k < 63) part[k++] = *s; s++; n--; }
        if (n > 0) { s++; n--; }
        part[k] = 0;
        if (!k || !strcmp(part, ".") || !strcmp(part, "..")) continue;
        for (i = 0; i < k; i++) {
            unsigned char c = part[i];
            if (c == '.') dot = i;
            if (c <= ' ' || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|' || c >= 0x7F) part[i] = '_';
            else part[i] = upper(c);
        }
        if (k > 15) {                           /* too long: its base cut */
            if (dot > 0 && k - dot <= 5) {
                int ext = k - dot, keep = 15 - ext;
                memmove(part + keep, part + dot, ext + 1);
            } else part[15] = 0;
        }
        if (o && o < PATH_MAX - 1) outp[o++] = '/';
        for (i = 0; part[i] && o < PATH_MAX - 1; i++) outp[o++] = part[i];
    }
    outp[o] = 0;
}
/* every folder on the way to path (and path itself, if dir) made */
static void make_dirs(const char *path, int last_too)
{
    char p[PATH_MAX];
    int i;
    for (i = 0; path[i] && i < PATH_MAX - 1; i++) {
        p[i] = path[i];
        if (path[i] == '/' && i) { p[i] = 0; mkdir(p); p[i] = '/'; }
    }
    p[i] = 0;
    if (last_too && i) mkdir(p);
}

static int unpack(const char *archive, const char *dest, int list)
{
    int count, cd, i, files = 0, failed = 0;
    char base[PATH_MAX];
    if (load_zip(archive) < 0) return 1;
    cd = find_cd(&count);
    if (cd < 0 || cd >= zipn) { finish("zip: that isn't a ZIP archive"); return 1; }
    if (!list) {
        if (dest) copy(base, dest, PATH_MAX);
        else {                                  /* "SITE.ZIP" -> "SITE" */
            const char *b = archive, *s;
            int k;
            for (s = archive; *s; s++) if (*s == '/') b = s + 1;
            copy(base, archive, PATH_MAX);
            k = b - archive;
            for (i = k; base[i] && base[i] != '.'; i++);
            base[i] = 0;
            if (i == k) copy(base + k, "UNZIPPED", PATH_MAX - k);
        }
        for (i = 0; base[i]; i++) base[i] = upper(base[i]);
        make_dirs(base, 1);
        say("Unpacking into "); say(base); say("\n");
    }
    for (i = 0; i < count; i++) {
        unsigned char *c = zip + cd;
        int method, csize, usize, nl, xl, cl, lo, data;
        unsigned crc;
        char name[PATH_MAX], full[PATH_MAX];
        if (cd + 46 > zipn || rd32(c) != 0x02014b50) { finish("zip: the archive is damaged"); return 1; }
        method = rd16(c + 10); crc = rd32(c + 16); csize = rd32(c + 20); usize = rd32(c + 24);
        nl = rd16(c + 28); xl = rd16(c + 30); cl = rd16(c + 32); lo = rd32(c + 42);
        lexos_name((char *)c + 46, nl, name);
        cd += 46 + nl + xl + cl;
        if (list) {
            char raw[PATH_MAX];
            int k = nl < PATH_MAX - 1 ? nl : PATH_MAX - 1;
            memcpy(raw, c + 46, k);
            raw[k] = 0;
            puts("  "); puts(raw); puts("  "); print_int(usize);
            if (method == 8) { puts(" ("); print_int(csize); puts(" packed)"); }
            puts("\n");
            continue;
        }
        if (!name[0]) continue;
        copy(full, base, PATH_MAX);
        append(full, "/", PATH_MAX);
        append(full, name, PATH_MAX);
        if (c[46 + nl - 1] == '/') { make_dirs(full, 1); continue; }     /* a folder */
        make_dirs(full, 0);
        if (lo + 30 > zipn || rd32(zip + lo) != 0x04034b50) { failed++; continue; }
        data = lo + 30 + rd16(zip + lo + 26) + rd16(zip + lo + 28);
        if (data + csize > zipn) { failed++; continue; }
        {
            unsigned char *buf = malloc(usize + 1);
            int got = -1, fd;
            if (!buf) { say("  too big: "); say(full); say("\n"); failed++; continue; }
            if (method == 0 && csize == usize) { memcpy(buf, zip + data, usize); got = usize; }
            else if (method == 8) got = inflate(zip + data, csize, buf, usize);
            if (got != usize || crc32(buf, usize) != crc) {
                say("  damaged, or packed a way zip doesn't know: "); say(full); say("\n");
                failed++;
                free(buf);
                continue;
            }
            fd = open(full, O_WRITE);
            if (fd < 0 || fwrite(fd, buf, usize) != usize) { say("  can't write "); say(full); say("\n"); failed++; }
            if (fd >= 0) close(fd);
            free(buf);
            files++;
            if (!quiet) { puts("  "); puts(full); puts("  "); print_int(usize); puts(" bytes\n"); }
        }
    }
    if (list) return 0;
    copy(msg, "Unpacked ", sizeof msg);
    append_num(msg, files - failed, sizeof msg);
    append(msg, " files into ", sizeof msg);
    append(msg, base, sizeof msg);
    if (failed) { append(msg, " (", sizeof msg); append_num(msg, failed, sizeof msg); append(msg, " failed)", sizeof msg); }
    finish(msg);
    return failed ? 1 : 0;
}

int main(int argc, char **argv)
{
    int a = 1, mode = 0;
    crc_init();
    while (a < argc && argv[a][0] == '-') {
        char f = argv[a][1];
        if (f == 'q' || f == 'Q') quiet = 1;
        else if (f == 'x' || f == 'X') mode = 1;
        else if (f == 'l' || f == 'L') mode = 2;
        a++;
    }
    if (a >= argc || (mode == 0 && a + 1 >= argc)) {
        puts("zip ARCHIVE.ZIP NAME...      - pack files and folders\n"
             "zip -x ARCHIVE.ZIP [FOLDER]  - unpack (into a folder named after it)\n"
             "zip -l ARCHIVE.ZIP           - what's in it\n");
        return 1;
    }
    if (mode == 1) return unpack(argv[a], a + 1 < argc ? argv[a + 1] : 0, 0);
    if (mode == 2) return unpack(argv[a], 0, 1);
    return pack(argv[a], argv + a + 1, argc - a - 1);
}
