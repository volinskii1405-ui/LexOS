/* browser.c - LexOS Web: a web browser in a window.
 *
 *   run browser.app [address]
 *
 * Opens pages from LexOS's own disk (/DEMOS/SITE/INDEX.HTM - the start
 * page) or from the web over plain http:// (fetch(): src/appsys.asm,
 * the same code as `wget`). It knows the HTML a simple page needs:
 * headings, paragraphs, line breaks, bold/italic/underlined text, links,
 * lists (bullets and numbers), <pre>, <hr>, <blockquote>, <center>,
 * tables as rows of cells, <font color>, <body bgcolor>, and pictures -
 * <img> of .BMP files (8, 24 or 32 bits, as `paint` saves them). Text in
 * UTF-8 is shown in LexOS's font (Russian and Spanish letters too);
 * scripts and styles are skipped.
 *
 * The mouse: click a link, the wheel scrolls, the scrollbar drags. The
 * keys: arrows, PgUp/PgDn, Home/End, Space - scroll; Backspace - back;
 * Tab (or a click on it) - the address bar, Enter there goes; F5 -
 * reload; Esc - quit. */
#include "lexos.h"

#define W 800
#define H 600
#define BAR 36                            /* the toolbar */
#define STATUS 20                         /* the status line */
#define VIEW_Y BAR
#define VIEW_H (H - BAR - STATUS)
#define SBW 14                            /* the scrollbar */
#define MARGIN 18
#define RIGHT (W - SBW - MARGIN)

#define SRC_MAX (256 * 1024)
#define ITEMS_MAX 9000
#define POOL_MAX (160 * 1024)
#define LINKS_MAX 600
#define LPOOL_MAX (40 * 1024)
#define URL_MAX 240
#define HIST_MAX 32

/* colors */
#define C_PAGE   RGB(255, 255, 255)
#define C_TEXT   RGB(32, 32, 40)
#define C_LINK   RGB(26, 80, 208)
#define C_HEAD   RGB(16, 40, 90)
#define C_PRE    RGB(240, 242, 246)
#define C_RULE   RGB(196, 200, 210)
#define C_BAR    RGB(226, 232, 242)
#define C_BAR_LO RGB(170, 180, 198)
#define C_BTN    RGB(248, 250, 253)
#define C_HOVER  RGB(206, 222, 250)
#define C_STATUS RGB(236, 238, 242)
#define C_GRAY   RGB(110, 116, 128)

static unsigned frame[W * H];
static unsigned char glyphs[4096];
static char src[SRC_MAX + 1];
static int srclen;

/* --- what's on the page: a list of items, laid out --- */
enum { IT_TEXT, IT_RULE, IT_IMAGE, IT_BOX };
#define ST_BOLD  1
#define ST_ITAL  2
#define ST_UNDER 4
struct item {
    int x, y, w, h;
    unsigned char kind, style, scale, pad;
    short link;
    int text, len;                        /* IT_TEXT: in pool */
    unsigned color;
    unsigned *pix;                        /* IT_IMAGE */
};
static struct item items[ITEMS_MAX];
static int nitems;
static char pool[POOL_MAX];
static int npool;
static int link_off[LINKS_MAX];
static int nlinks;
static char lpool[LPOOL_MAX];
static int nlpool;
static unsigned page_bg;
static int doc_h, scroll;
static char title[80];

/* --- where we are --- */
static char url[URL_MAX], edit_url[URL_MAX];
static char hist[HIST_MAX][URL_MAX];
static int nhist, hpos = -1;
static int editing, hover_link = -1, hover_btn = -1;
static char status[URL_MAX + 40];
static const char *home = "/DEMOS/SITE/INDEX.HTM";

/* ============================================================
 * little helpers
 * ============================================================ */
static int lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
static int is_space(int c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'; }
static int starts_ci(const char *s, const char *p)
{
    while (*p) if (lower((unsigned char)*s++) != lower((unsigned char)*p++)) return 0;
    return 1;
}
static void copy(char *d, const char *s, int n)
{
    while (--n > 0 && *s) *d++ = *s++;
    *d = 0;
}
static void append(char *d, const char *s, int n)
{
    int l = strlen(d);
    copy(d + l, s, n - l);
}
static int hexval(int c)
{
    c = lower(c);
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

/* ============================================================
 * drawing
 * ============================================================ */
static void fill(int x, int y, int w, int h, unsigned c, int y0, int y1)
{
    int i, j;
    if (x < 0) { w += x; x = 0; }
    if (x + w > W) w = W - x;
    if (y < y0) { h -= y0 - y; y = y0; }
    if (y + h > y1) h = y1 - y;
    for (j = 0; j < h; j++) {
        unsigned *p = frame + (y + j) * W + x;
        for (i = 0; i < w; i++) p[i] = c;
    }
}

/* one character, scale s, clipped to rows y0..y1 */
static void glyph(int x, int y, unsigned char ch, unsigned c, int s, int style, int y0, int y1)
{
    int r, b, i, j;
    const unsigned char *g = glyphs + ch * 16;
    for (r = 0; r < 16; r++) {
        unsigned bits = g[r];
        int sh = (style & ST_ITAL) && r < 8 ? 1 : 0;
        if (style & ST_BOLD) bits |= bits >> 1;
        if (!bits) continue;
        for (b = 0; b < 8; b++) {
            if (!(bits & (0x80 >> b))) continue;
            for (j = 0; j < s; j++) {
                int yy = y + r * s + j;
                if (yy < y0 || yy >= y1) continue;
                for (i = 0; i < s; i++) {
                    int xx = x + (b + sh) * s + i;
                    if (xx >= 0 && xx < W) frame[yy * W + xx] = c;
                }
            }
        }
    }
}

static void text_at(int x, int y, const char *t, unsigned c, int style, int maxw)
{
    while (*t && maxw >= 8) {
        glyph(x, y, (unsigned char)*t++, c, 1, style, 0, H);
        x += 8;
        maxw -= 8;
    }
}

/* ============================================================
 * UTF-8 and entities -> LexOS's font (code page 866, and the Spanish
 * letters src/lang.asm puts in place)
 * ============================================================ */
static int to_font(unsigned u, char *out)
{
    if (u < 128) { out[0] = (char)u; return 1; }
    if (u >= 0x410 && u <= 0x43F) { out[0] = (char)(0x80 + u - 0x410); return 1; }
    if (u >= 0x440 && u <= 0x44F) { out[0] = (char)(0xE0 + u - 0x440); return 1; }
    switch (u) {
    case 0x401: out[0] = (char)0xF0; return 1;    /* Ё ё */
    case 0x451: out[0] = (char)0xF1; return 1;
    case 0xE1: out[0] = (char)0xF2; return 1;     /* á é í ó ú ñ Ñ ü ¿ ¡ */
    case 0xE9: out[0] = (char)0xF3; return 1;
    case 0xED: out[0] = (char)0xF4; return 1;
    case 0xF3: out[0] = (char)0xF5; return 1;
    case 0xFA: out[0] = (char)0xF6; return 1;
    case 0xF1: out[0] = (char)0xF7; return 1;
    case 0xD1: out[0] = (char)0xFC; return 1;
    case 0xFC: out[0] = (char)0xFD; return 1;
    case 0xBF: out[0] = (char)0xB5; return 1;
    case 0xA1: out[0] = (char)0xB6; return 1;
    case 0xC1: out[0] = 'A'; return 1;
    case 0xC9: out[0] = 'E'; return 1;
    case 0xCD: out[0] = 'I'; return 1;
    case 0xD3: out[0] = 'O'; return 1;
    case 0xDA: out[0] = 'U'; return 1;
    case 0xA0: out[0] = ' '; return 1;            /* no-break space */
    case 0x2013: case 0x2014: case 0x2212: out[0] = '-'; return 1;
    case 0x2018: case 0x2019: out[0] = '\''; return 1;
    case 0x201C: case 0x201D: case 0xAB: case 0xBB: out[0] = '"'; return 1;
    case 0x2022: case 0xB7: out[0] = 7; return 1;
    case 0x2026: out[0] = out[1] = out[2] = '.'; return 3;
    case 0xA9: out[0] = '('; out[1] = 'c'; out[2] = ')'; return 3;
    case 0xB0: out[0] = (char)0xF8; return 1;
    case 0x2192: out[0] = 0x1A; return 1;
    case 0x2190: out[0] = 0x1B; return 1;
    }
    out[0] = '?';
    return 1;
}

/* the character at src[*p] (UTF-8), *p past it */
static unsigned utf8(int *p)
{
    unsigned c = (unsigned char)src[*p];
    int n = 0;
    unsigned u;
    (*p)++;
    if (c < 0x80) return c;
    if ((c & 0xE0) == 0xC0) { u = c & 0x1F; n = 1; }
    else if ((c & 0xF0) == 0xE0) { u = c & 0x0F; n = 2; }
    else if ((c & 0xF8) == 0xF0) { u = c & 0x07; n = 3; }
    else return '?';
    while (n-- && *p < srclen && (src[*p] & 0xC0) == 0x80)
        u = u << 6 | (src[(*p)++] & 0x3F);
    return u;
}

static const struct { const char *name; unsigned u; } entities[] = {
    { "amp", '&' }, { "lt", '<' }, { "gt", '>' }, { "quot", '"' }, { "apos", '\'' },
    { "nbsp", 0xA0 }, { "copy", 0xA9 }, { "mdash", 0x2014 }, { "ndash", 0x2013 },
    { "laquo", 0xAB }, { "raquo", 0xBB }, { "hellip", 0x2026 }, { "bull", 0x2022 },
    { "middot", 0xB7 }, { "deg", 0xB0 }, { "rarr", 0x2192 }, { "larr", 0x2190 },
    { "lsquo", 0x2018 }, { "rsquo", 0x2019 }, { "ldquo", 0x201C }, { "rdquo", 0x201D },
    { "aacute", 0xE1 }, { "eacute", 0xE9 }, { "iacute", 0xED }, { "oacute", 0xF3 },
    { "uacute", 0xFA }, { "ntilde", 0xF1 }, { "Ntilde", 0xD1 }, { "iquest", 0xBF },
    { "iexcl", 0xA1 }, { "uuml", 0xFC }, { 0, 0 }
};

/* src[*p] is '&': the character it stands for, *p past it */
static unsigned entity(int *p)
{
    int q = *p + 1, i;
    char name[12];
    int n = 0;
    if (q < srclen && src[q] == '#') {
        unsigned u = 0;
        q++;
        if (q < srclen && lower(src[q]) == 'x') {
            q++;
            while (q < srclen && hexval(src[q]) >= 0) u = u * 16 + hexval(src[q++]);
        } else
            while (q < srclen && src[q] >= '0' && src[q] <= '9') u = u * 10 + src[q++] - '0';
        if (q < srclen && src[q] == ';') q++;
        *p = q;
        return u;
    }
    while (q < srclen && n < 10 && ((src[q] >= 'a' && src[q] <= 'z') || (src[q] >= 'A' && src[q] <= 'Z')))
        name[n++] = src[q++];
    name[n] = 0;
    for (i = 0; entities[i].name; i++)
        if (!strcmp(entities[i].name, name)) {
            if (q < srclen && src[q] == ';') q++;
            *p = q;
            return entities[i].u;
        }
    (*p)++;
    return '&';
}

/* ============================================================
 * layout: the HTML read once, items placed as it goes
 * ============================================================ */
static int x, y, line_start, line_left, pending_space, last_gap;
static int bold, ital, under, pre, center, scale, head, cur_link;
static int indent, list_depth, list_num[8], list_ordered[8];
static unsigned color_stack[8];
static int ncolor;
static char word[256];
static int wlen;

static unsigned cur_color(void)
{
    if (cur_link >= 0) return C_LINK;
    if (ncolor) return color_stack[ncolor - 1];
    if (head) return C_HEAD;
    return C_TEXT;
}

static int cur_style(void)
{
    return (bold || head ? ST_BOLD : 0) | (ital ? ST_ITAL : 0) | (under || cur_link >= 0 ? ST_UNDER : 0);
}

static struct item *new_item(int kind)
{
    struct item *it;
    if (nitems >= ITEMS_MAX) return 0;
    it = &items[nitems++];
    memset(it, 0, sizeof *it);
    it->kind = kind;
    it->link = -1;
    return it;
}

/* the line so far: placed on its baseline, centered if it should be */
static void end_line(int force)
{
    int i, lh = 0, dx = 0;
    for (i = line_start; i < nitems; i++)
        if (items[i].kind != IT_BOX && items[i].h > lh) lh = items[i].h;
    if (!lh) {
        if (force) { y += 16 * scale + 2; last_gap = 0; }
        x = line_left;
        pending_space = 0;
        return;
    }
    if (center) dx = (RIGHT - x) / 2;
    for (i = line_start; i < nitems; i++) {
        if (items[i].kind == IT_BOX) continue;
        items[i].x += dx;
        items[i].y = y + lh - items[i].h;
    }
    y += lh + 3;
    line_start = nitems;
    x = line_left;
    pending_space = 0;
    last_gap = 0;
}

/* a block begins or ends: the line ended, and space above what's next */
static void block(int gap)
{
    end_line(0);
    if (gap > last_gap) { y += gap - last_gap; last_gap = gap; }
}

static void set_left(int left)
{
    line_left = left;
    if (line_start == nitems) x = left;
}

static void emit_text(const char *t, int n)
{
    struct item *it;
    int cw = 8 * scale, w = n * cw;
    if (pending_space && x > line_left) {
        if (x + cw + w <= RIGHT) x += cw;
        else end_line(0);
    }
    pending_space = 0;
    if (x + w > RIGHT && x > line_left) end_line(0);
    while (n > 0) {
        int fit = (RIGHT - x) / cw, k;
        if (fit < 1) fit = 1;
        k = n < fit ? n : fit;
        if (npool + k > POOL_MAX || !(it = new_item(IT_TEXT))) return;
        memcpy(pool + npool, t, k);
        it->text = npool;
        it->len = k;
        npool += k;
        it->x = x;
        it->w = k * cw;
        it->h = 16 * scale;
        it->scale = scale;
        it->style = cur_style();
        it->color = cur_color();
        it->link = cur_link;
        x += k * cw;
        t += k;
        n -= k;
        if (n > 0) end_line(0);
    }
}

static void flush_word(void)
{
    if (wlen) emit_text(word, wlen);
    wlen = 0;
}

static void put_char(unsigned u)
{
    char out[3];
    int n, i;
    if (pre) {
        if (u == '\n') { flush_word(); end_line(1); return; }
        if (u == '\r') return;
        if (u == '\t') {                  /* to the next column of 8 */
            int col = (x - line_left) / 8 + wlen;
            do { word[wlen++] = ' '; col++; } while (col % 8 && wlen < (int)sizeof word - 1);
            flush_word();
            return;
        }
    } else if (u < 128 && is_space(u)) {
        flush_word();
        pending_space = 1;
        return;
    }
    n = to_font(u, out);
    for (i = 0; i < n; i++) {
        if (wlen >= (int)sizeof word - 1) flush_word();
        word[wlen++] = out[i];
    }
    if (pre && u == ' ') flush_word();
}

/* --- links --- */
static int add_link(const char *href)
{
    int n = strlen(href) + 1;
    if (nlinks >= LINKS_MAX || nlpool + n > LPOOL_MAX) return -1;
    link_off[nlinks] = nlpool;
    memcpy(lpool + nlpool, href, n);
    nlpool += n;
    return nlinks++;
}

/* --- addresses --- */
static int is_http(const char *u) { return starts_ci(u, "http://"); }

/* "a/b/../c/./d" -> "a/c/d" (in place, from where the path starts) */
static void tidy_path(char *p)
{
    char out[URL_MAX];
    int o = 0, i = 0;
    while (p[i]) {
        if (p[i] == '/' && p[i + 1] == '.' && (p[i + 2] == '/' || !p[i + 2])) { i += 2; continue; }
        if (p[i] == '/' && p[i + 1] == '.' && p[i + 2] == '.' && (p[i + 3] == '/' || !p[i + 3])) {
            while (o > 0 && out[o - 1] != '/') o--;
            if (o > 0) o--;
            i += 3;
            continue;
        }
        if (o < URL_MAX - 1) out[o++] = p[i];
        i++;
    }
    out[o] = 0;
    if (!o) { out[0] = '/'; out[1] = 0; }
    strcpy(p, out);
}

/* href, seen on page `base` -> out */
static void resolve(const char *base, const char *href, char *out)
{
    char h[URL_MAX];
    int i;
    copy(h, href, URL_MAX);
    for (i = 0; h[i]; i++) if (h[i] == '#') { h[i] = 0; break; }
    if (is_http(h) || starts_ci(h, "https://")) { copy(out, h, URL_MAX); return; }
    if (starts_ci(h, "file:")) { copy(out, h + 5, URL_MAX); return; }
    if (h[0] == '/' && h[1] == '/') { copy(out, "http:", URL_MAX); append(out, h, URL_MAX); return; }
    if (is_http(base)) {
        const char *hs = base + 7, *slash = hs;
        int n;
        while (*slash && *slash != '/') slash++;
        n = slash - base;
        if (n >= URL_MAX) n = URL_MAX - 1;
        memcpy(out, base, n);
        out[n] = 0;
        if (h[0] == '/') append(out, h, URL_MAX);
        else {
            const char *last = base + strlen(base);
            char dir[URL_MAX];
            while (last > slash && last[-1] != '/') last--;
            n = last - slash;
            if (n >= URL_MAX) n = URL_MAX - 1;
            memcpy(dir, slash, n);
            dir[n] = 0;
            if (!dir[0]) strcpy(dir, "/");
            append(dir, h, URL_MAX);
            tidy_path(dir);
            append(out, dir, URL_MAX);
        }
        tidy_path(out + (slash - base));
        return;
    }
    if (h[0] == '/') { copy(out, h, URL_MAX); tidy_path(out); return; }
    {                                     /* on this disk, relative */
        const char *last = base + strlen(base);
        int n;
        while (last > base && last[-1] != '/') last--;
        n = last - base;
        if (n >= URL_MAX) n = URL_MAX - 1;
        memcpy(out, base, n);
        out[n] = 0;
        append(out, h, URL_MAX);
        if (out[0] == '/') tidy_path(out);
    }
}

/* --- pictures: BMP --- */
static unsigned rd16(const unsigned char *p) { return p[0] | p[1] << 8; }
static unsigned rd32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (unsigned)p[3] << 24; }

static unsigned *load_bmp(const unsigned char *b, int n, int *pw, int *ph)
{
    int w, h, bpp, off, stride, r, c, down = 0;
    const unsigned char *pal;
    unsigned *pix;
    if (n < 54 || b[0] != 'B' || b[1] != 'M') return 0;
    off = rd32(b + 10);
    w = (int)rd32(b + 18);
    h = (int)rd32(b + 22);
    bpp = rd16(b + 28);
    if (rd32(b + 30) != 0 && !(bpp == 32 && rd32(b + 30) == 3)) return 0;
    if (h < 0) { h = -h; down = 1; }
    if (w <= 0 || h <= 0 || w > 1024 || h > 1024) return 0;
    if (bpp != 8 && bpp != 24 && bpp != 32) return 0;
    stride = (w * bpp / 8 + 3) & ~3;
    if (off + stride * h > n) return 0;
    pal = b + 14 + rd32(b + 14);
    pix = malloc(w * h * 4);
    if (!pix) return 0;
    for (r = 0; r < h; r++) {
        const unsigned char *row = b + off + stride * (down ? r : h - 1 - r);
        for (c = 0; c < w; c++) {
            unsigned v;
            if (bpp == 8) { const unsigned char *q = pal + row[c] * 4; v = RGB(q[2], q[1], q[0]); }
            else if (bpp == 24) v = RGB(row[c * 3 + 2], row[c * 3 + 1], row[c * 3]);
            else v = RGB(row[c * 4 + 2], row[c * 4 + 1], row[c * 4]);
            pix[r * w + c] = v;
        }
    }
    *pw = w;
    *ph = h;
    return pix;
}

/* a file (this disk) or a page (http) -> buf; its length, or <0 */
static int load(const char *where, char *buf, int max)
{
    int fd, n, tries;
    char u[URL_MAX];
    if (is_http(where)) {
        copy(u, where, URL_MAX);
        for (tries = 0; tries < 4; tries++) {
            n = fetch(u, buf, max);
            if (n != -3) return n;
            buf[max - 1] = 0;
            {
                char moved[URL_MAX];
                resolve(u, buf, moved);
                copy(u, moved, URL_MAX);
            }
            if (!is_http(u)) return -2;
        }
        return -1;
    }
    fd = open(where, O_READ);
    if (fd < 0) return -1;
    n = read(fd, buf, max);
    close(fd);
    return n;
}

static void emit_image(const char *srcattr, const char *alt)
{
    char where[URL_MAX];
    int n, w = 0, h = 0, f = 1;
    unsigned *pix = 0;
    unsigned char *buf = malloc(512 * 1024);
    resolve(url, srcattr, where);
    if (buf) {
        n = load(where, (char *)buf, 512 * 1024);
        if (n > 0) pix = load_bmp(buf, n, &w, &h);
        free(buf);
    }
    if (!pix) {                           /* not shown: its words instead */
        int save = ital;
        const char *a = alt && *alt ? alt : "[picture]";
        ital = 1;
        flush_word();
        pending_space = 1;
        while (*a) put_char((unsigned char)*a++);
        flush_word();
        ital = save;
        return;
    }
    while (w / f > RIGHT - line_left) f++;  /* too wide: smaller */
    if (f > 1) {
        int nw = w / f, nh = h / f, r, c;
        unsigned *small = malloc(nw * nh * 4);
        if (small) {
            for (r = 0; r < nh; r++)
                for (c = 0; c < nw; c++) small[r * nw + c] = pix[r * f * w + c * f];
            free(pix);
            pix = small;
            w = nw;
            h = nh;
        }
    }
    flush_word();
    if (pending_space && x > line_left) x += 8;
    pending_space = 0;
    if (x + w > RIGHT && x > line_left) end_line(0);
    {
        struct item *it = new_item(IT_IMAGE);
        if (!it) { free(pix); return; }
        it->x = x;
        it->w = w;
        it->h = h;
        it->pix = pix;
        it->link = cur_link;
    }
    x += w;
}

/* --- tags --- */
#define ATTRS 8
static char aname[ATTRS][16], aval[ATTRS][URL_MAX];
static int nattrs;

static const char *attr(const char *name)
{
    int i;
    for (i = 0; i < nattrs; i++) if (!strcmp(aname[i], name)) return aval[i];
    return 0;
}

static unsigned parse_color(const char *s, unsigned dflt)
{
    unsigned v = 0;
    int i;
    static const struct { const char *n; unsigned c; } named[] = {
        { "red", 0xCC2222 }, { "green", 0x118811 }, { "blue", 0x2233CC }, { "black", 0 },
        { "white", 0xFFFFFF }, { "gray", 0x808080 }, { "grey", 0x808080 }, { "yellow", 0xEEDD22 },
        { "orange", 0xEE8811 }, { "purple", 0x882299 }, { "navy", 0x112266 }, { "maroon", 0x800000 },
        { "teal", 0x118888 }, { "silver", 0xC0C0C0 }, { "lightblue", 0xADD8E6 }, { 0, 0 } };
    if (!s) return dflt;
    if (*s == '#') s++;
    else
        for (i = 0; named[i].n; i++) if (starts_ci(s, named[i].n) && !s[strlen(named[i].n)]) return named[i].c;
    for (i = 0; i < 6; i++) {
        int h = hexval(s[i]);
        if (h < 0) {
            if (i == 3) return (v >> 8 & 15) * 0x110000 | (v >> 4 & 15) * 0x1100 | (v & 15) * 0x11;
            return dflt;
        }
        v = v << 4 | h;
    }
    return v;
}

/* the rest of a tag we don't show: skipped up to </name> */
static void skip_to_end(int *p, const char *name)
{
    int n = strlen(name);
    while (*p < srclen) {
        if (src[*p] == '<' && src[*p + 1] == '/' && starts_ci(src + *p + 2, name) &&
            (src[*p + 2 + n] == '>' || is_space(src[*p + 2 + n]))) {
            while (*p < srclen && src[*p] != '>') (*p)++;
            (*p)++;
            return;
        }
        (*p)++;
    }
}

static void list_item(void)
{
    char mark[8];
    struct item *it;
    int d = list_depth > 0 ? list_depth - 1 : 0;
    block(2);
    if (list_ordered[d]) {
        int n = ++list_num[d], k = 0;
        char t[6];
        do { t[k++] = '0' + n % 10; n /= 10; } while (n && k < 5);
        n = 0;
        while (k) mark[n++] = t[--k];
        mark[n++] = '.';
        mark[n] = 0;
    } else {
        mark[0] = d % 2 ? (char)0xF9 : 7;
        mark[1] = 0;
    }
    if (npool + 8 <= POOL_MAX && (it = new_item(IT_TEXT))) {
        int n = strlen(mark);
        memcpy(pool + npool, mark, n);
        it->text = npool;
        it->len = n;
        npool += n;
        it->x = line_left - n * 8 - 6;
        it->w = n * 8;
        it->h = 16;
        it->scale = 1;
        it->color = cur_color();
    }
}

static void heading(int level, int open)
{
    static const int gap[] = { 0, 18, 16, 14, 12, 10, 10 };
    block(gap[level]);
    if (open) {
        head = level;
        scale = level <= 2 ? 2 : 1;
    } else {
        head = 0;
        scale = 1;
    }
}

static void tag(int *p)
{
    char name[16];
    int n = 0, closing = 0, q = *p + 1;
    if (starts_ci(src + q, "!--")) {                    /* a comment */
        q += 3;
        while (q < srclen && !(src[q] == '-' && src[q + 1] == '-' && src[q + 2] == '>')) q++;
        *p = q + 3;
        return;
    }
    if (src[q] == '/') { closing = 1; q++; }
    while (q < srclen && n < 15 && ((src[q] >= 'a' && src[q] <= 'z') || (src[q] >= 'A' && src[q] <= 'Z') || (src[q] >= '0' && src[q] <= '9')))
        name[n++] = lower(src[q++]);
    name[n] = 0;
    if (!n) {                                           /* "<" as text, <!DOCTYPE>... */
        if (src[q] == '!' || src[q] == '?') {
            while (q < srclen && src[q] != '>') q++;
            *p = q + 1;
            return;
        }
        put_char('<');
        (*p)++;
        return;
    }
    nattrs = 0;                                         /* its attributes */
    while (q < srclen && src[q] != '>') {
        int k = 0;
        if (is_space(src[q]) || src[q] == '/') { q++; continue; }
        while (q < srclen && !is_space(src[q]) && src[q] != '=' && src[q] != '>') {
            if (k < 15 && nattrs < ATTRS) aname[nattrs][k++] = lower(src[q]);
            q++;
        }
        if (nattrs < ATTRS) aname[nattrs][k] = 0;
        while (q < srclen && is_space(src[q])) q++;
        k = 0;
        if (src[q] == '=') {
            q++;
            while (q < srclen && is_space(src[q])) q++;
            if (src[q] == '"' || src[q] == '\'') {
                char quote = src[q++];
                while (q < srclen && src[q] != quote) {
                    if (k < URL_MAX - 1 && nattrs < ATTRS) aval[nattrs][k++] = src[q];
                    q++;
                }
                q++;
            } else
                while (q < srclen && !is_space(src[q]) && src[q] != '>') {
                    if (k < URL_MAX - 1 && nattrs < ATTRS) aval[nattrs][k++] = src[q];
                    q++;
                }
        }
        if (nattrs < ATTRS) aval[nattrs++][k] = 0;
    }
    *p = q + 1;

    if (!strcmp(name, "script") || !strcmp(name, "style") || !strcmp(name, "noscript") ||
        !strcmp(name, "svg") || !strcmp(name, "template")) {
        if (!closing) skip_to_end(p, name);
        return;
    }
    if (!strcmp(name, "title")) {
        int t = 0;
        if (closing) return;
        while (*p < srclen && src[*p] != '<') {
            char out[3];
            unsigned u = src[*p] == '&' ? entity(p) : utf8(p);
            int k, m = to_font(is_space(u) ? ' ' : u, out);
            for (k = 0; k < m && t < (int)sizeof title - 1; k++) title[t++] = out[k];
        }
        title[t] = 0;
        skip_to_end(p, "title");
        return;
    }
    flush_word();
    if (name[0] == 'h' && name[1] >= '1' && name[1] <= '6' && !name[2]) { heading(name[1] - '0', !closing); return; }
    if (!strcmp(name, "br")) { end_line(1); return; }
    if (!strcmp(name, "p") || !strcmp(name, "div") || !strcmp(name, "section") || !strcmp(name, "article") ||
        !strcmp(name, "header") || !strcmp(name, "footer") || !strcmp(name, "nav") || !strcmp(name, "main") ||
        !strcmp(name, "form") || !strcmp(name, "table") || !strcmp(name, "dl") || !strcmp(name, "address") ||
        !strcmp(name, "figure") || !strcmp(name, "aside")) {
        block(!strcmp(name, "p") || !strcmp(name, "table") ? 10 : 4);
        return;
    }
    if (!strcmp(name, "tr") || !strcmp(name, "dt") || !strcmp(name, "figcaption")) { block(2); return; }
    if (!strcmp(name, "dd")) { block(2); set_left(closing ? line_left - 32 : line_left + 32); return; }
    if (!strcmp(name, "td") || !strcmp(name, "th")) {
        if (!closing) { pending_space = 1; if (x > line_left) x += 16; }
        if (!strcmp(name, "th")) bold += closing ? -1 : 1;
        if (bold < 0) bold = 0;
        return;
    }
    if (!strcmp(name, "center")) { block(4); center = !closing; return; }
    if (!strcmp(name, "blockquote")) {
        block(8);
        indent += closing ? -36 : 36;
        if (indent < 0) indent = 0;
        set_left(MARGIN + indent + list_depth * 28);
        if (!closing) ital++; else if (ital) ital--;
        return;
    }
    if (!strcmp(name, "ul") || !strcmp(name, "ol") || !strcmp(name, "menu")) {
        block(list_depth ? 2 : 8);
        if (!closing) {
            if (list_depth < 8) { list_ordered[list_depth] = name[0] == 'o'; list_num[list_depth] = 0; }
            list_depth++;
        } else if (list_depth) list_depth--;
        set_left(MARGIN + indent + list_depth * 28);
        return;
    }
    if (!strcmp(name, "li")) { if (!closing) list_item(); return; }
    if (!strcmp(name, "pre") || !strcmp(name, "listing") || !strcmp(name, "xmp")) {
        static int box_at, box_y;
        block(8);
        if (!closing) {
            struct item *it = new_item(IT_BOX);
            box_at = it ? nitems - 1 : -1;
            box_y = y;
            y += 6;
            pre = 1;
            line_start = nitems;
        } else {
            pre = 0;
            y += 6;
            if (box_at >= 0) {
                items[box_at].x = line_left - 8;
                items[box_at].y = box_y;
                items[box_at].w = RIGHT - line_left + 16;
                items[box_at].h = y - box_y;
                items[box_at].color = C_PRE;
            }
            block(8);
        }
        return;
    }
    if (!strcmp(name, "hr")) {
        struct item *it;
        block(8);
        if ((it = new_item(IT_RULE))) {
            it->x = line_left;
            it->y = y;
            it->w = RIGHT - line_left;
            it->h = 2;
            it->color = C_RULE;
        }
        y += 2;
        line_start = nitems;
        block(8);
        return;
    }
    if (!strcmp(name, "a")) {
        const char *h = attr("href");
        if (closing) cur_link = -1;
        else if (h) cur_link = add_link(h);
        return;
    }
    if (!strcmp(name, "b") || !strcmp(name, "strong")) { bold += closing ? -1 : 1; if (bold < 0) bold = 0; return; }
    if (!strcmp(name, "i") || !strcmp(name, "em") || !strcmp(name, "cite") || !strcmp(name, "var")) {
        ital += closing ? -1 : 1; if (ital < 0) ital = 0; return;
    }
    if (!strcmp(name, "u") || !strcmp(name, "ins")) { under += closing ? -1 : 1; if (under < 0) under = 0; return; }
    if (!strcmp(name, "font")) {
        if (closing) { if (ncolor) ncolor--; }
        else if (ncolor < 8) color_stack[ncolor++] = parse_color(attr("color"), cur_color());
        return;
    }
    if (!strcmp(name, "body")) { if (!closing) page_bg = parse_color(attr("bgcolor"), C_PAGE); return; }
    if (!strcmp(name, "img")) { const char *s = attr("src"); if (s) emit_image(s, attr("alt")); return; }
    if (!strcmp(name, "input") || !strcmp(name, "button") || !strcmp(name, "select") || !strcmp(name, "textarea")) {
        const char *v = attr("value");
        if (!closing && v && *v) { pending_space = 1; put_char('['); while (*v) put_char((unsigned char)*v++); put_char(']'); flush_word(); }
        return;
    }
}

static void free_page(void)
{
    int i;
    for (i = 0; i < nitems; i++) if (items[i].pix) free(items[i].pix);
    nitems = npool = nlinks = nlpool = 0;
}

static void layout(void)
{
    int p = 0;
    free_page();
    x = line_left = MARGIN;
    y = 14;
    line_start = 0;
    pending_space = 0;
    last_gap = 14;
    bold = ital = under = pre = center = head = 0;
    scale = 1;
    cur_link = -1;
    indent = list_depth = ncolor = 0;
    wlen = 0;
    title[0] = 0;
    page_bg = C_PAGE;
    while (p < srclen) {
        unsigned char c = src[p];
        if (c == '<') tag(&p);
        else if (c == '&') put_char(entity(&p));
        else put_char(utf8(&p));
    }
    flush_word();
    end_line(0);
    doc_h = y + 20;
    scroll = 0;
}

/* ============================================================
 * the window: toolbar, page, scrollbar, status
 * ============================================================ */
#define BTN_Y 6
#define BTN_H 24
static const int btn_x[] = { 8, 38, 68, 98 };
#define ADDR_X 132
#define GO_X (W - 44)
#define ADDR_W (GO_X - 8 - ADDR_X)

static void bevel(int bx, int by, int bw, int bh, unsigned face)
{
    fill(bx, by, bw, bh, C_BAR_LO, 0, H);
    fill(bx + 1, by + 1, bw - 2, bh - 2, face, 0, H);
}

static void draw_bar(void)
{
    static const char *labels[] = { "\x1b", "\x1a", "R", "\x7f" };
    int i;
    fill(0, 0, W, BAR, C_BAR, 0, H);
    fill(0, BAR - 1, W, 1, C_BAR_LO, 0, H);
    for (i = 0; i < 4; i++) {
        int dim = (i == 0 && hpos <= 0) || (i == 1 && hpos >= nhist - 1);
        bevel(btn_x[i], BTN_Y, 26, BTN_H, hover_btn == i && !dim ? C_HOVER : C_BTN);
        text_at(btn_x[i] + 9, BTN_Y + 4, labels[i], dim ? C_RULE : C_TEXT, ST_BOLD, 16);
    }
    fill(ADDR_X, BTN_Y, ADDR_W, BTN_H, editing ? C_LINK : C_BAR_LO, 0, H);
    fill(ADDR_X + 1, BTN_Y + 1, ADDR_W - 2, BTN_H - 2, C_PAGE, 0, H);
    {
        const char *t = editing ? edit_url : url;
        int len = strlen(t), vis = (ADDR_W - 16) / 8;
        if (len > vis) t += len - vis;
        text_at(ADDR_X + 7, BTN_Y + 4, t, C_TEXT, 0, ADDR_W - 12);
        if (editing) fill(ADDR_X + 7 + (int)strlen(t) * 8, BTN_Y + 4, 2, 16, C_LINK, 0, H);
    }
    bevel(GO_X, BTN_Y, 36, BTN_H, hover_btn == 4 ? C_HOVER : C_BTN);
    text_at(GO_X + 10, BTN_Y + 4, "Go", C_TEXT, ST_BOLD, 24);
}

static void draw_page(void)
{
    int i, top = VIEW_Y, bot = VIEW_Y + VIEW_H;
    fill(0, top, W - SBW, VIEW_H, page_bg, 0, H);
    for (int pass = 0; pass < 2; pass++)
        for (i = 0; i < nitems; i++) {
            struct item *it = &items[i];
            int sy = it->y - scroll + top;
            if ((it->kind == IT_BOX) != (pass == 0)) continue;
            if (sy + it->h < top || sy >= bot) continue;
            if (it->kind == IT_BOX || it->kind == IT_RULE) fill(it->x, sy, it->w, it->h, it->color, top, bot);
            else if (it->kind == IT_IMAGE) {
                int r, c;
                for (r = 0; r < it->h; r++) {
                    int yy = sy + r;
                    if (yy < top || yy >= bot) continue;
                    for (c = 0; c < it->w && it->x + c < W - SBW; c++) frame[yy * W + it->x + c] = it->pix[r * it->w + c];
                }
                if (it->link >= 0 && it->link == hover_link) {
                    fill(it->x, sy, it->w, 2, C_LINK, top, bot);
                    fill(it->x, sy + it->h - 2, it->w, 2, C_LINK, top, bot);
                }
            } else {
                int k, s = it->scale;
                unsigned c = it->color;
                if (it->link >= 0 && it->link == hover_link) c = RGB(200, 40, 60);
                for (k = 0; k < it->len; k++)
                    glyph(it->x + k * 8 * s, sy, (unsigned char)pool[it->text + k], c, s, it->style, top, bot);
                if (it->style & ST_UNDER) fill(it->x, sy + 15 * s - 1, it->w, s, c, top, bot);
            }
        }
    /* the scrollbar */
    fill(W - SBW, top, SBW, VIEW_H, RGB(236, 238, 242), 0, H);
    fill(W - SBW, top, 1, VIEW_H, C_RULE, 0, H);
    if (doc_h > VIEW_H) {
        int th = VIEW_H * VIEW_H / doc_h, ty;
        if (th < 24) th = 24;
        ty = top + (VIEW_H - th) * scroll / (doc_h - VIEW_H);
        fill(W - SBW + 3, ty + 2, SBW - 5, th - 4, RGB(160, 170, 188), 0, H);
    }
}

static void draw_status(void)
{
    const char *t = status;
    fill(0, H - STATUS, W, STATUS, C_STATUS, 0, H);
    fill(0, H - STATUS, W, 1, C_RULE, 0, H);
    if (hover_link >= 0) t = lpool + link_off[hover_link];
    else if (!*t && title[0]) t = title;
    text_at(8, H - STATUS + 2, t, C_GRAY, 0, W - 120);
    text_at(W - 88, H - STATUS + 2, "LexOS Web", C_RULE, ST_BOLD, 88);
}

static void redraw(void)
{
    draw_bar();
    draw_page();
    draw_status();
    gfx_blit(frame);
}

/* ============================================================
 * going places
 * ============================================================ */
static void error_page(const char *what, const char *where)
{
    char *s = src;
    const char *parts[] = { "<title>Can't open this page</title><body><h1>Can't open this page</h1><p>",
                            what, "</p><p><b>", where,
                            "</b></p><hr><p>Pages can be on this disk (<a href=\"/DEMOS/SITE/INDEX.HTM\">"
                            "/DEMOS/SITE/INDEX.HTM</a>) or on the web over <b>http://</b> - "
                            "https needs encryption LexOS doesn't have.</p>", 0 };
    int i;
    *s = 0;
    for (i = 0; parts[i]; i++) append(s, parts[i], SRC_MAX);
    srclen = strlen(src);
}

static void clamp_scroll(void)
{
    int max = doc_h - VIEW_H;
    if (scroll > max) scroll = max;
    if (scroll < 0) scroll = 0;
}

static void go(const char *to, int remember)
{
    int n;
    char where[URL_MAX];
    copy(where, to, URL_MAX);
    if (!where[0]) return;
    if (!is_http(where) && !starts_ci(where, "https://") && where[0] != '/' &&
        (starts_ci(where, "www.") || (strlen(where) > 4 && !starts_ci(where + strlen(where) - 4, ".htm") &&
                                     !starts_ci(where + strlen(where) - 5, ".html")))) {
        char t[URL_MAX];                  /* "example.com" -> http:// */
        copy(t, "http://", URL_MAX);
        append(t, where, URL_MAX);
        copy(where, t, URL_MAX);
    }
    copy(url, where, URL_MAX);
    copy(status, "Loading ", sizeof status);
    append(status, where, sizeof status);
    append(status, " ...", sizeof status);
    hover_link = -1;
    redraw();
    if (starts_ci(where, "https://")) {
        error_page("LexOS can't open https:// pages: they need encryption (TLS) it doesn't have. Try http://.", where);
    } else {
        n = load(where, src, SRC_MAX);
        if (n >= 0) srclen = n;
        else error_page(n == -2 ? "The server answered, but not with the page (not found, or not allowed)."
                                : is_http(where) ? "No answer - is the network up? (ifconfig, dhcp)"
                                                 : "There's no such file on this disk.", where);
    }
    src[srclen] = 0;
    if (remember) {
        if (hpos < HIST_MAX - 1) hpos++;
        else memmove(hist[0], hist[1], sizeof hist[0] * (HIST_MAX - 1));
        copy(hist[hpos], url, URL_MAX);
        nhist = hpos + 1;
    }
    layout();
    status[0] = 0;
    redraw();
}

static int item_at(int mx, int my)
{
    int i, dy = my - VIEW_Y + scroll;
    for (i = 0; i < nitems; i++) {
        struct item *it = &items[i];
        if (it->link < 0) continue;
        if (mx >= it->x && mx < it->x + it->w && dy >= it->y && dy < it->y + it->h) return it->link;
    }
    return -1;
}

static int button_at(int mx, int my)
{
    int i;
    if (my < BTN_Y || my >= BTN_Y + BTN_H) return -1;
    for (i = 0; i < 4; i++) if (mx >= btn_x[i] && mx < btn_x[i] + 26) return i;
    if (mx >= GO_X && mx < GO_X + 36) return 4;
    if (mx >= ADDR_X && mx < ADDR_X + ADDR_W) return 5;
    return -1;
}

static void press(int b)
{
    if (b == 0 && hpos > 0) { hpos--; go(hist[hpos], 0); }
    else if (b == 1 && hpos < nhist - 1) { hpos++; go(hist[hpos], 0); }
    else if (b == 2) { int s = scroll; go(url, 0); scroll = s; clamp_scroll(); redraw(); }
    else if (b == 3) go(home, 1);
    else if (b == 4) { editing = 0; go(edit_url, 1); }
    else if (b == 5 && !editing) { editing = 1; copy(edit_url, url, URL_MAX); redraw(); }
}

int main(int argc, char **argv)
{
    int m[4], was_down = 0, drag = -1, drag_scroll = 0;
    if (gfx_mode_ex(W, H, 32) < 0) { puts("browser: needs 800x600 in 32 bits\n"); return 1; }
    font(glyphs);
    go(argc > 1 ? argv[1] : home, 1);
    for (;;) {
        int k = pollkey(), changed = 0, over;
        if (k) {
            int ch = k & 0xFF, sc = (k >> 8) & 0xFF;
            if (editing) {
                int l = strlen(edit_url);
                if (ch == 13) { editing = 0; go(edit_url, 1); }
                else if (ch == 27) editing = 0;
                else if (ch == 8) { if (l) edit_url[l - 1] = 0; }
                else if (ch >= 32 && ch < 127 && l < URL_MAX - 1) { edit_url[l] = ch; edit_url[l + 1] = 0; }
                changed = 1;
            } else if (ch == 27) break;
            else if (ch == 9 || ch == 12) { press(5); }
            else if (ch == 8) press(0);
            else if (sc == 0x3F) press(2);                    /* F5 */
            else {
                int s = scroll;
                if (sc == 0x48) scroll -= 48;
                else if (sc == 0x50) scroll += 48;
                else if (sc == 0x49) scroll -= VIEW_H - 40;
                else if (sc == 0x51 || ch == ' ') scroll += VIEW_H - 40;
                else if (sc == 0x47) scroll = 0;
                else if (sc == 0x4F) scroll = doc_h;
                clamp_scroll();
                changed = s != scroll;
            }
        }
        over = mouse(m);
        if (m[3]) {
            int s = scroll;
            scroll += m[3] * 48;
            clamp_scroll();
            changed |= s != scroll;
        }
        if (over) {
            int down = m[2] & 1, mx = m[0], my = m[1];
            int hl = my >= VIEW_Y && my < VIEW_Y + VIEW_H && mx < W - SBW ? item_at(mx, my) : -1;
            int hb = button_at(mx, my);
            if (hl != hover_link || hb != hover_btn) { hover_link = hl; hover_btn = hb; changed = 1; }
            if (down && !was_down) {
                if (mx >= W - SBW && my >= VIEW_Y && my < VIEW_Y + VIEW_H) {
                    drag = my;                             /* the scrollbar */
                    drag_scroll = scroll;
                    if (doc_h > VIEW_H) {
                        int th = VIEW_H * VIEW_H / doc_h, ty;
                        if (th < 24) th = 24;
                        ty = VIEW_Y + (VIEW_H - th) * scroll / (doc_h - VIEW_H);
                        if (my < ty || my >= ty + th) {    /* off the thumb: a page */
                            scroll += my < ty ? -(VIEW_H - 40) : VIEW_H - 40;
                            clamp_scroll();
                            drag_scroll = scroll;
                            changed = 1;
                        }
                    }
                } else if (hb >= 0) {
                    if (editing && hb != 4 && hb != 5) editing = 0;
                    press(hb);
                    changed = 1;
                } else if (hl >= 0) {
                    char to[URL_MAX];
                    editing = 0;
                    resolve(url, lpool + link_off[hl], to);
                    go(to, 1);
                    continue;
                } else if (editing) { editing = 0; changed = 1; }
            } else if (down && drag >= 0 && doc_h > VIEW_H) {
                int th = VIEW_H * VIEW_H / doc_h, s = scroll;
                if (th < 24) th = 24;
                if (VIEW_H > th) scroll = drag_scroll + (my - drag) * (doc_h - VIEW_H) / (VIEW_H - th);
                clamp_scroll();
                changed |= s != scroll;
            }
            if (!down) drag = -1;
            was_down = down;
        } else {
            if (hover_link >= 0 || hover_btn >= 0) { hover_link = hover_btn = -1; changed = 1; }
            was_down = 0;
            drag = -1;
        }
        if (changed) redraw();
        sleep_ms(15);
    }
    return 0;
}
