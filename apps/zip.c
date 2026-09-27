/* zip.c - ZIP archives: packing and unpacking.
 *
 *   zip.app ARCHIVE.ZIP NAME...        pack files and folders into it
 *   zip.app -x ARCHIVE.ZIP [FOLDER]    unpack it (into a folder named
 *                                      after it, next to it, if none)
 *   zip.app -l ARCHIVE.ZIP             what's in it
 *   zip.app -v ARCHIVE.ZIP             look into it in a window: its
 *                                      folders, sizes, a text or picture
 *                                      shown; extract all or what's chosen
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

#include "deflate.h"

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
            l = df_len_base[sym] + get_bits(df_len_extra[sym]);
            dsym = decode(dc);
            if (dsym < 0 || dsym >= 30) { inf_err = 1; return -1; }
            d = df_dist_base[dsym] + get_bits(df_dist_extra[dsym]);
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

/* ============================================================
 * zip -v: a window to look into an archive - its folders, each file's
 * size and how well it packed, a text or a picture shown before it's
 * unpacked; Extract all, or just what's chosen
 * ============================================================ */
#define VW 720
#define VH 500
#define V_BAR 34
#define V_TOP 58
#define V_ROW 20
#define V_LISTW 430
#define V_STATUS 22
#define V_ROWS ((VH - V_TOP - V_STATUS) / V_ROW)
#define C_BG   RGB(255, 255, 255)
#define C_TEXT RGB(28, 30, 36)
#define C_GRAY RGB(110, 116, 128)
#define C_BAR  RGB(226, 232, 242)
#define C_LO   RGB(170, 180, 198)
#define C_BTN  RGB(248, 250, 253)
#define C_HOV  RGB(206, 222, 250)
#define C_SEL  RGB(184, 212, 250)
#define C_ACC  RGB(40, 90, 200)

static unsigned *vf;

/* a of b, in percent (no 64-bit division here) */
static int pct(unsigned a, unsigned b)
{
    if (!b) return 100;
    if (a < 40000000) return a * 100 / b;
    return a / (b / 100 ? b / 100 : 1);
}
static unsigned char glyphs[4096];

struct zent { char disp[PATH_MAX]; char name[PATH_MAX]; int method, csize, usize, lo, dir; unsigned crc; unsigned short time, date; };
static struct zent *zents;
static int nz;
struct child { char name[48]; int dir, idx, files; unsigned size, csize; };
static struct child kids[MAX_ENTRIES];
static int nkids, vscroll, vsel = -1, vhover = -1;
static char vprefix[PATH_MAX], varchive[PATH_MAX], vstatus[96];
static unsigned char *pv;                     /* the chosen one, unpacked */
static int pvn, pv_kind;                      /* 0 none, 1 text, 2 picture, 3 binary, 4 folder */

static int to866(unsigned u)
{
    static const unsigned short su[] = { 0xE1, 0xE9, 0xED, 0xF3, 0xFA, 0xF1, 0xD1, 0xFC, 0xBF, 0xA1, 0xE7, 0xC7, 0xB0, 0 };
    static const unsigned char sb[] = { 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xFC, 0xFD, 0xB5, 0xB6, 0xB7, 0xB8, 0xF8 };
    int i;
    if (u < 128) return u;
    if (u >= 0x410 && u <= 0x43F) return 0x80 + u - 0x410;
    if (u >= 0x440 && u <= 0x44F) return 0xE0 + u - 0x440;
    if (u == 0x401) return 0xF0;
    if (u == 0x451) return 0xF1;
    for (i = 0; su[i]; i++) if (su[i] == u) return sb[i];
    return '?';
}
/* UTF-8 bytes -> the font's (in place, n -> the new length); bytes that
 * aren't UTF-8 are kept as they are */
static int from_utf8(unsigned char *t, int n)
{
    int i = 0, j = 0;
    while (i < n) {
        unsigned c = t[i], u;
        int k;
        if (c < 0x80) { t[j++] = c; i++; continue; }
        if ((c & 0xE0) == 0xC0) { u = c & 0x1F; k = 1; }
        else if ((c & 0xF0) == 0xE0) { u = c & 0x0F; k = 2; }
        else { t[j++] = c; i++; continue; }
        if (i + k >= n) { t[j++] = c; i++; continue; }
        {
            int m, ok = 1;
            for (m = 1; m <= k; m++) if ((t[i + m] & 0xC0) != 0x80) ok = 0;
            if (!ok) { t[j++] = c; i++; continue; }
            for (m = 1; m <= k; m++) u = u << 6 | (t[i + m] & 0x3F);
        }
        t[j++] = to866(u);
        i += k + 1;
    }
    return j;
}

static int parse_zip(void)
{
    int count, cd, i;
    cd = find_cd(&count);
    if (cd < 0 || cd >= zipn) return -1;
    zents = malloc(sizeof(struct zent) * (count ? count : 1));
    if (!zents) return -1;
    for (i = nz = 0; i < count; i++) {
        unsigned char *c = zip + cd;
        struct zent *e = &zents[nz];
        int nl, xl, cl, k;
        if (cd + 46 > zipn || rd32(c) != 0x02014b50) break;
        e->method = rd16(c + 10); e->time = rd16(c + 12); e->date = rd16(c + 14);
        e->crc = rd32(c + 16); e->csize = rd32(c + 20); e->usize = rd32(c + 24);
        nl = rd16(c + 28); xl = rd16(c + 30); cl = rd16(c + 32); e->lo = rd32(c + 42);
        k = nl < PATH_MAX - 1 ? nl : PATH_MAX - 1;
        memcpy(e->disp, c + 46, k);
        e->disp[k] = 0;
        for (k = 0; e->disp[k]; k++) if (e->disp[k] == '\\') e->disp[k] = '/';
        e->disp[from_utf8((unsigned char *)e->disp, strlen(e->disp))] = 0;
        e->dir = nl && c[46 + nl - 1] == '/';
        if (e->dir && e->disp[0]) e->disp[strlen(e->disp) - 1] = 0;
        lexos_name((char *)c + 46, nl, e->name);
        cd += 46 + nl + xl + cl;
        if (e->disp[0]) nz++;
    }
    return 0;
}

/* an entry, unpacked -> malloc'd, its length in *n; 0 if it can't be */
static unsigned char *entry_data(struct zent *e, int *n)
{
    int data;
    unsigned char *buf;
    if (e->lo + 30 > zipn || rd32(zip + e->lo) != 0x04034b50) return 0;
    data = e->lo + 30 + rd16(zip + e->lo + 26) + rd16(zip + e->lo + 28);
    if (data + e->csize > zipn) return 0;
    buf = malloc(e->usize + 1);
    if (!buf) return 0;
    if (e->method == 0 && e->csize == e->usize) memcpy(buf, zip + data, e->usize);
    else if (e->method != 8 || inflate(zip + data, e->csize, buf, e->usize) != e->usize) { free(buf); return 0; }
    if (crc32(buf, e->usize) != e->crc) { free(buf); return 0; }
    *n = e->usize;
    return buf;
}

static int starts(const char *s, const char *p) { while (*p) if (*s++ != *p++) return 0; return 1; }

/* the children of vprefix -> kids[], folders first */
static void list_kids(void)
{
    int i, j, pl = strlen(vprefix);
    nkids = 0;
    for (i = 0; i < nz; i++) {
        struct zent *e = &zents[i];
        const char *rest, *slash;
        char nm[48];
        int isdir, k;
        if (!starts(e->disp, vprefix) || !e->disp[pl]) continue;
        rest = e->disp + pl;
        slash = rest;
        while (*slash && *slash != '/') slash++;
        isdir = *slash == '/' || e->dir;
        k = slash - rest < 47 ? slash - rest : 47;
        memcpy(nm, rest, k);
        nm[k] = 0;
        for (j = 0; j < nkids; j++) if (!strcmp(kids[j].name, nm) && kids[j].dir == isdir) break;
        if (j == nkids) {
            if (nkids >= MAX_ENTRIES) continue;
            memset(&kids[j], 0, sizeof kids[j]);
            copy(kids[j].name, nm, sizeof kids[j].name);
            kids[j].dir = isdir;
            kids[j].idx = isdir ? -1 : i;
            nkids++;
        }
        if (!e->dir) { kids[j].size += e->usize; kids[j].csize += e->csize; if (isdir) kids[j].files++; }
    }
    for (i = 1; i < nkids; i++) {                /* folders first, by name */
        struct child t = kids[i];
        for (j = i; j > 0; j--) {
            struct child *p = &kids[j - 1];
            if (p->dir > t.dir || (p->dir == t.dir && strcmp(p->name, t.name) <= 0)) break;
            kids[j] = *p;
        }
        kids[j] = t;
    }
    vscroll = 0;
    vsel = -1;
    free(pv); pv = 0; pv_kind = 0;
}

/* drawing */
static void vfill(int x, int y, int w, int h, unsigned c)
{
    int i, j;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > VW) w = VW - x;
    if (y + h > VH) h = VH - y;
    for (j = 0; j < h; j++) for (i = 0; i < w; i++) vf[(y + j) * VW + x + i] = c;
}
static void vglyph(int x, int y, unsigned char ch, unsigned c)
{
    int r, b;
    const unsigned char *g = glyphs + ch * 16;
    if (x < 0 || x > VW - 8 || y < 0 || y > VH - 16) return;
    for (r = 0; r < 16; r++) for (b = 0; b < 8; b++) if (g[r] & (0x80 >> b)) vf[(y + r) * VW + x + b] = c;
}
static void vtext(int x, int y, const char *t, unsigned c, int maxw)
{
    while (*t && maxw >= 8) { vglyph(x, y, (unsigned char)*t++, c); x += 8; maxw -= 8; }
}
static void vbutton(int x, int w, const char *l, int lit)
{
    vfill(x, 5, w, 24, C_LO);
    vfill(x + 1, 6, w - 2, 22, lit ? C_HOV : C_BTN);
    vtext(x + (w - 8 * (int)strlen(l)) / 2, 9, l, C_TEXT, w);
}
static const int vbx[] = { 8, 64, 176 };
static const int vbw[] = { 50, 106, 146 };
static const char *vbl[] = { "Up", "Extract all", "Extract chosen" };

static void size_text(char *d, unsigned v)
{
    d[0] = 0;
    if (v < 10240) { append_num(d, v, 20); append(d, " B", 20); }
    else if (v < 10485760) { append_num(d, (v + 512) / 1024, 20); append(d, " KB", 20); }
    else { append_num(d, (v + 524288) / 1048576, 20); append(d, " MB", 20); }
}

static void icon_small(int x, int y, int dir)
{
    if (dir) { vfill(x, y + 4, 16, 11, RGB(241, 196, 15)); vfill(x, y + 2, 7, 3, RGB(212, 160, 23)); }
    else { vfill(x + 2, y, 12, 16, C_GRAY); vfill(x + 3, y + 1, 10, 14, RGB(255, 255, 255)); vfill(x + 5, y + 5, 6, 1, C_LO); vfill(x + 5, y + 8, 6, 1, C_LO); vfill(x + 5, y + 11, 4, 1, C_LO); }
}

static void draw_preview(void)
{
    int x0 = V_LISTW + 8, y = V_TOP + 4, w = VW - x0 - 8, h = VH - V_STATUS - y - 4;
    struct child *k;
    char t[64];
    vfill(V_LISTW, V_TOP - 2, VW - V_LISTW, VH - V_STATUS - V_TOP + 2, RGB(246, 248, 252));
    vfill(V_LISTW, V_TOP - 2, 1, VH - V_STATUS - V_TOP + 2, C_LO);
    if (vsel < 0) { vtext(x0, y, "Choose something to see it here.", C_GRAY, w); return; }
    k = &kids[vsel];
    vtext(x0, y, k->name, C_TEXT, w);
    y += 20;
    if (k->dir) {
        t[0] = 0; append(t, "A folder: ", 64); append_num(t, k->files, 64); append(t, " files", 64);
        vtext(x0, y, t, C_GRAY, w);
        y += 18;
        size_text(t, k->size); append(t, " in all", 64);
        vtext(x0, y, t, C_GRAY, w);
        vtext(x0, y + 30, "Double-click: in.", C_GRAY, w);
        return;
    }
    {
        struct zent *e = &zents[k->idx];
        t[0] = 0;
        size_text(t, e->usize);
        if (e->method == 8 && e->usize) {
            append(t, ", packed to ", 64);
            append_num(t, e->usize ? pct(e->csize, e->usize) : 100, 64);
            append(t, "%", 64);
        } else append(t, ", stored", 64);
        vtext(x0, y, t, C_GRAY, w);
        y += 18;
        if (e->date) {
            t[0] = 0;
            if ((e->date & 31) < 10) append(t, "0", 64);
            append_num(t, e->date & 31, 64); append(t, ".", 64);
            if ((e->date >> 5 & 15) < 10) append(t, "0", 64);
            append_num(t, e->date >> 5 & 15, 64); append(t, ".", 64);
            append_num(t, (e->date >> 9) + 1980, 64); append(t, " ", 64);
            if ((e->time >> 11) < 10) append(t, "0", 64);
            append_num(t, e->time >> 11, 64); append(t, ":", 64);
            if ((e->time >> 5 & 63) < 10) append(t, "0", 64);
            append_num(t, e->time >> 5 & 63, 64);
            vtext(x0, y, t, C_GRAY, w);
        }
        y += 24;
    }
    vfill(x0 - 2, y - 4, w + 4, 1, C_LO);
    h = VH - V_STATUS - y - 4;
    if (pv_kind == 3) { vtext(x0, y, "Not text - nothing to show.", C_GRAY, w); return; }
    if (pv_kind == 0) { vtext(x0, y, "It can't be unpacked (damaged?).", RGB(200, 60, 60), w); return; }
    if (pv_kind == 2) {                        /* a .BMP, fitted in */
        unsigned char *b = pv;
        int bw = rd32(b + 18), bh = (int)rd32(b + 22), bpp = rd16(b + 28), off = rd32(b + 10);
        int flip = bh > 0, ah = bh < 0 ? -bh : bh, stride, sx, sy, dx, dy, dw, dh;
        stride = ((bw * bpp + 31) / 32) * 4;
        dw = w; dh = bw ? ah * w / bw : 0;
        if (dh > h) { dh = h; dw = ah ? bw * h / ah : 0; }
        if (dw > bw * 2) { dw = bw * 2; dh = ah * 2; }
        for (dy = 0; dy < dh; dy++)
            for (dx = 0; dx < dw; dx++) {
                unsigned char *px;
                unsigned c;
                sx = dx * bw / dw; sy = dy * ah / dh;
                if (flip) sy = ah - 1 - sy;
                px = b + off + sy * stride;
                if (off + sy * stride + stride > pvn) continue;
                if (bpp == 24) c = RGB(px[sx * 3 + 2], px[sx * 3 + 1], px[sx * 3]);
                else if (bpp == 32) c = RGB(px[sx * 4 + 2], px[sx * 4 + 1], px[sx * 4]);
                else { unsigned char *pal = b + 14 + rd32(b + 14); int ix = px[sx]; c = RGB(pal[ix * 4 + 2], pal[ix * 4 + 1], pal[ix * 4]); }
                vf[(y + dy) * VW + x0 + dx] = c;
            }
        t[0] = 0; append_num(t, bw, 64); append(t, " x ", 64); append_num(t, ah, 64);
        append(t, ", ", 64); append_num(t, bpp, 64); append(t, " bits", 64);
        vtext(x0, y + dh + 6, t, C_GRAY, w);
        return;
    }
    {                                           /* text: lines, wrapped */
        int i = 0, col = 0, maxc = w / 8, row = 0, rows = h / 16;
        while (i < pvn && row < rows) {
            unsigned char c = pv[i++];
            if (c == '\r') continue;
            if (c == '\n' || col >= maxc) { row++; col = 0; if (c == '\n') continue; }
            if (c == '\t') { col = (col / 4 + 1) * 4; continue; }
            if (row < rows) vglyph(x0 + col * 8, y + row * 16, c, C_TEXT);
            col++;
        }
    }
}

static void vredraw(void)
{
    int i;
    char t[96];
    vfill(0, 0, VW, V_BAR, C_BAR);
    vfill(0, V_BAR - 1, VW, 1, C_LO);
    for (i = 0; i < 3; i++) vbutton(vbx[i], vbw[i], vbl[i], vhover == i);
    t[0] = 0;
    {
        int files = 0; unsigned us = 0, cs = 0;
        for (i = 0; i < nz; i++) if (!zents[i].dir) { files++; us += zents[i].usize; cs += zents[i].csize; }
        append_num(t, files, 96); append(t, files == 1 ? " file, " : " files, ", 96);
        size_text(t + strlen(t), us);
        if (us) { append(t, " (", 96); append_num(t, pct(cs, us), 96); append(t, "%)", 96); }
    }
    vtext(VW - 8 - 8 * (int)strlen(t), 9, t, C_GRAY, 400);
    vfill(0, V_BAR, VW, V_TOP - V_BAR - 2, C_BG);
    t[0] = 0; append(t, varchive, 96); append(t, " / ", 96); append(t, vprefix, 96);
    vtext(8, V_BAR + 4, t, C_ACC, VW - 16);
    vfill(0, V_TOP - 2, V_LISTW, VH - V_STATUS - V_TOP + 2, C_BG);
    for (i = 0; i < V_ROWS && vscroll + i < nkids; i++) {
        struct child *k = &kids[vscroll + i];
        int y = V_TOP + i * V_ROW;
        char sz[24];
        if (vscroll + i == vsel) vfill(0, y, V_LISTW, V_ROW, C_SEL);
        icon_small(8, y + 2, k->dir);
        vtext(30, y + 2, k->name, C_TEXT, 250);
        if (k->dir) { sz[0] = 0; append_num(sz, k->files, 24); append(sz, k->files == 1 ? " file" : " files", 24); }
        else size_text(sz, k->size);
        vtext(V_LISTW - 90 - 8 * (int)strlen(sz) / 2, y + 2, sz, C_GRAY, 120);
        if (!k->dir && k->size && k->csize < k->size) {
            char pc[8]; pc[0] = 0;
            append_num(pc, pct(k->csize, k->size), 8); append(pc, "%", 8);
            vtext(V_LISTW - 12 - 8 * (int)strlen(pc), y + 2, pc, C_GRAY, 40);
        }
    }
    if (nkids > V_ROWS) {
        int th = VH - V_STATUS - V_TOP, tl = th * V_ROWS / nkids, ty = V_TOP + (th - tl) * vscroll / (nkids - V_ROWS);
        vfill(V_LISTW - 6, ty, 4, tl, C_LO);
    }
    draw_preview();
    vfill(0, VH - V_STATUS, VW, V_STATUS, RGB(236, 238, 242));
    vfill(0, VH - V_STATUS, VW, 1, C_LO);
    vtext(8, VH - V_STATUS + 3, vstatus[0] ? vstatus : "Double-click: open a folder. Backspace: up. Esc: close.",
          vstatus[0] ? C_ACC : C_GRAY, VW - 16);
    gfx_blit(vf);
}

static void choose(int i)
{
    vsel = i;
    free(pv); pv = 0; pv_kind = 0; pvn = 0;
    vstatus[0] = 0;
    if (i < 0) return;
    if (i < vscroll) vscroll = i;
    if (i >= vscroll + V_ROWS) vscroll = i - V_ROWS + 1;
    if (kids[i].dir) { pv_kind = 4; return; }
    {
        struct zent *e = &zents[kids[i].idx];
        int n = 0, bad = 0, k;
        if (e->usize > 2 * 1024 * 1024) { pv_kind = 3; return; }
        pv = entry_data(e, &n);
        if (!pv) return;
        pvn = n;
        if (n > 54 && pv[0] == 'B' && pv[1] == 'M' && (rd16(pv + 28) == 8 || rd16(pv + 28) == 24 || rd16(pv + 28) == 32) && rd32(pv + 30) == 0) { pv_kind = 2; return; }
        for (k = 0; k < n && k < 4096; k++) if (pv[k] == 0 || (pv[k] < 32 && pv[k] != '\n' && pv[k] != '\r' && pv[k] != '\t' && pv[k] != 27 && pv[k] != 12)) bad++;
        if (bad) { pv_kind = 3; return; }
        pvn = from_utf8(pv, n);
        pv_kind = 1;
    }
}

/* what's under the chosen (or everything: all) -> the folder named after
 * the archive, its path from the folder shown kept */
static void extract(int all)
{
    char base[PATH_MAX], want[PATH_MAX];
    int i, k, files = 0, failed = 0, skip;
    const char *b = varchive, *s;
    for (s = varchive; *s; s++) if (*s == '/') b = s + 1;
    copy(base, varchive, PATH_MAX);
    k = b - varchive;
    for (i = k; base[i] && base[i] != '.'; i++);
    base[i] = 0;
    if (i == k) copy(base + k, "UNZIPPED", PATH_MAX - k);
    for (i = 0; base[i]; i++) base[i] = upper(base[i]);
    if (!all) {
        if (vsel < 0) { copy(vstatus, "Choose a file or a folder first.", sizeof vstatus); return; }
        copy(want, vprefix, PATH_MAX);
        append(want, kids[vsel].name, PATH_MAX);
    }
    skip = 0;                                  /* the folder shown: its parts left out */
    if (!all) for (s = vprefix; *s; s++) if (*s == '/') skip++;
    make_dirs(base, 1);
    copy(vstatus, "Unpacking...", sizeof vstatus);
    vredraw();
    for (i = 0; i < nz; i++) {
        struct zent *e = &zents[i];
        char full[PATH_MAX];
        const char *nm = e->name;
        int n, fd, sk;
        unsigned char *d;
        if (!all) {
            int wl = strlen(want);
            if (!starts(e->disp, want) || (e->disp[wl] && e->disp[wl] != '/')) continue;
        }
        for (sk = skip; sk && *nm; nm++) if (*nm == '/') sk--;
        if (!*nm) continue;
        copy(full, base, PATH_MAX); append(full, "/", PATH_MAX); append(full, nm, PATH_MAX);
        if (e->dir) { make_dirs(full, 1); continue; }
        make_dirs(full, 0);
        d = entry_data(e, &n);
        if (!d) { failed++; continue; }
        fd = open(full, O_WRITE);
        if (fd < 0 || fwrite(fd, d, n) != n) failed++; else files++;
        if (fd >= 0) close(fd);
        free(d);
    }
    copy(vstatus, "Unpacked ", sizeof vstatus);
    append_num(vstatus, files, sizeof vstatus);
    append(vstatus, files == 1 ? " file into " : " files into ", sizeof vstatus);
    append(vstatus, base, sizeof vstatus);
    if (failed) { append(vstatus, " (", sizeof vstatus); append_num(vstatus, failed, sizeof vstatus); append(vstatus, " failed)", sizeof vstatus); }
    notify(vstatus);
}

static void go_up(void)
{
    int l = strlen(vprefix);
    if (!l) return;
    l--;                                       /* "A/B/" -> "A/" */
    while (l > 0 && vprefix[l - 1] != '/') l--;
    vprefix[l] = 0;
    list_kids();
}
static void open_kid(int i)
{
    if (i < 0 || i >= nkids || !kids[i].dir) return;
    append(vprefix, kids[i].name, PATH_MAX);
    append(vprefix, "/", PATH_MAX);
    list_kids();
}

static int view(const char *archive)
{
    int m[4], was = 0, i;
    unsigned last = 0;
    int lastrow = -1;
    quiet = 1;
    copy(varchive, archive, PATH_MAX);
    for (i = 0; varchive[i]; i++) varchive[i] = upper(varchive[i]);
    if (load_zip(varchive) < 0) return 1;
    if (parse_zip() < 0) { finish("zip: that isn't a ZIP archive"); return 1; }
    vf = malloc(VW * VH * 4);
    if (!vf || gfx_mode_ex(VW, VH, 32) < 0) { finish("zip: no room for its window"); return 1; }
    font(glyphs);
    list_kids();
    vredraw();
    for (;;) {
        int k = pollkey(), changed = 0, over;
        while (k) {
            int ch = k & 0xFF, sc = (k >> 8) & 0xFF;
            if (ch == 27) { gfx_mode(0); return 0; }
            if (ch == 8) go_up();
            else if (ch == 13) { if (vsel >= 0 && kids[vsel].dir) open_kid(vsel); }
            else if (!ch && sc == 0x48) choose(vsel > 0 ? vsel - 1 : 0);
            else if (!ch && sc == 0x50) choose(vsel < nkids - 1 ? vsel + 1 : nkids - 1);
            changed = 1;
            k = pollkey();
        }
        over = mouse(m);
        if (m[3]) {
            vscroll += m[3] * 3;
            if (vscroll > nkids - V_ROWS) vscroll = nkids - V_ROWS;
            if (vscroll < 0) vscroll = 0;
            changed = 1;
        }
        if (over) {
            int mx = m[0], my = m[1], down = m[2] & 1, hb = -1;
            if (my >= 5 && my < 29) for (i = 0; i < 3; i++) if (mx >= vbx[i] && mx < vbx[i] + vbw[i]) hb = i;
            if (hb != vhover) { vhover = hb; changed = 1; }
            if (down && !was) {
                unsigned now = millis();
                if (hb == 0) go_up();
                else if (hb == 1) extract(1);
                else if (hb == 2) extract(0);
                else if (mx < V_LISTW && my >= V_TOP && my < VH - V_STATUS) {
                    int r = vscroll + (my - V_TOP) / V_ROW;
                    if (r < nkids) {
                        if (r == lastrow && now - last < 450 && kids[r].dir) open_kid(r);
                        else if (r != vsel) choose(r);
                        lastrow = r;
                    }
                }
                last = now;
                changed = 1;
            }
            was = down;
        } else { if (vhover >= 0) { vhover = -1; changed = 1; } was = 0; }
        if (changed) vredraw();
        sleep_ms(15);
    }
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
        else if (f == 'v' || f == 'V') mode = 3;
        a++;
    }
    if (a >= argc || (mode == 0 && a + 1 >= argc)) {
        puts("zip ARCHIVE.ZIP NAME...      - pack files and folders\n"
             "zip -x ARCHIVE.ZIP [FOLDER]  - unpack (into a folder named after it)\n"
             "zip -l ARCHIVE.ZIP           - what's in it\n"
             "zip -v ARCHIVE.ZIP           - look into it, in a window\n");
        return 1;
    }
    if (mode == 1) return unpack(argv[a], a + 1 < argc ? argv[a + 1] : 0, 0);
    if (mode == 2) return unpack(argv[a], 0, 1);
    if (mode == 3) return view(argv[a]);
    return pack(argv[a], argv + a + 1, argc - a - 1);
}
