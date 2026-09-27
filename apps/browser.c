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
 * <img> of .BMP (8, 24 or 32 bits) and .PNG files (png.h). Text in
 * UTF-8 is shown in LexOS's font (Russian and Spanish letters too);
 * scripts and styles are skipped.
 *
 * https:// works too: apps/tls.h does TLS 1.3 (X25519, AES-GCM or
 * ChaCha20-Poly1305) over the kernel's TCP - encrypted, though the
 * server's certificate isn't checked (there's no list of authorities
 * to check it against).
 *
 * The mouse: click a link, the wheel scrolls, the scrollbar drags. The
 * keys: arrows, PgUp/PgDn, Home/End, Space - scroll; Backspace - back;
 * Tab (or a click on it) - the address bar, Enter there goes; F5 -
 * reload; Esc - quit.
 *
 * Downloads: a link to a file (not a page - a .ZIP, a .BMP, a .WAV...)
 * saves it in /DOWNLOADS as it comes, the status line counting (Esc
 * stops it); Ctrl+S saves the page itself; the arrow button by Go
 * lists what's been downloaded.
 *
 * Tabs: up to 8 pages open at once, along the top - a click goes to one,
 * its x closes it, + opens another (the start page); Ctrl+T, Ctrl+W,
 * Ctrl+Tab do the same from the keys, and Ctrl+click on a link opens it
 * in a new tab. Each keeps its address, its history and where it was
 * scrolled to, and - while there's memory for it - the page itself;
 * otherwise it's read again when it's gone back to. */
#include "lexos.h"
#include "tls.h"                         /* https:// - TLS 1.3 of its own */
#include "png.h"                         /* <img> of .PNG */

#define W 800
#define H 600
#define TABS_H 28                         /* the tabs */
#define BAR 36                            /* the toolbar */
#define BAR_Y TABS_H
#define STATUS 20                         /* the status line */
#define VIEW_Y (BAR_Y + BAR)
#define VIEW_H (H - VIEW_Y - STATUS)
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
static int editing, edit_fresh, hover_link = -1, hover_btn = -1;
static char status[URL_MAX + 40];
static const char *home = "/DEMOS/SITE/INDEX.HTM";

/* --- the tabs: the one in front lives in the globals above --- */
#define TABS_MAX 8
struct tab {
    char url[URL_MAX];
    char hist[HIST_MAX][URL_MAX];
    int nhist, hpos, scroll;
    char title[40];
    char *src;                            /* the page, kept (0: read again) */
    int srclen;
};
static struct tab tabs[TABS_MAX];
static int ntabs = 1, cur_tab, hover_tab = -1, hover_close = -1;

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
    if (u >= 0xC0 && u <= 0xFF) {                        /* other accents: the letter */
        static const char latin[] = "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYTsaaaaaaaceeeeiiiidnooooo/ouuuuyty";
        out[0] = u == 0xE7 ? (char)0xB7 : u == 0xC7 ? (char)0xB8 : latin[u - 0xC0];
        return 1;
    }
    if (u == 0x456 || u == 0x457) { out[0] = 'i'; return 1; }   /* Ukrainian */
    if (u == 0x454) { out[0] = (char)0xA5; return 1; }
    if (u == 0x491) { out[0] = (char)0xA3; return 1; }
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
static int is_https(const char *u) { return starts_ci(u, "https://"); }
static int is_http(const char *u) { return starts_ci(u, "http://") || is_https(u); }

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
    if (is_http(h)) { copy(out, h, URL_MAX); return; }
    if (starts_ci(h, "file:")) { copy(out, h + 5, URL_MAX); return; }
    if (h[0] == '/' && h[1] == '/') {
        copy(out, is_https(base) ? "https:" : "http:", URL_MAX);
        append(out, h, URL_MAX);
        return;
    }
    if (is_http(base)) {
        const char *hs = base + (is_https(base) ? 8 : 7), *slash = hs;
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

/* a PNG -> its pixels (up to 760 wide - less if memory's short:
 * shrunk), as load_bmp's */
static unsigned *png_pix;
static int png_pw;
static void png_to_pix(int x, int y, int r, int g, int b) { png_pix[y * png_pw + x] = RGB(r, g, b); }
static unsigned *load_png(unsigned char *b, int n, int *pw, int *ph)
{
    int w, h, mw = RIGHT - MARGIN, mh = 1024;
    for (;;) {                                  /* as big as memory lets it be */
        if (!png_size(b, n, mw, mh, &w, &h)) return 0;
        png_pix = malloc(w * h * 4);
        if (png_pix) break;
        if (w < 48 || h < 48) return 0;
        mw = w * 3 / 4; mh = h * 3 / 4;
    }
    png_pw = w;
    png_sink = png_to_pix;
    if (png_to_bmp(b, n, 0, 0, mw, mh) < 0) { png_sink = 0; free(png_pix); return 0; }
    png_sink = 0;
    *pw = w;
    *ph = h;
    return png_pix;
}

/* https://host[:port]/path -> buf, as fetch() does it for http (-3:
 * moved, the address in buf; -2: not the page; -4: TLS failed) */
static int parse_answer(char *buf, int len, int max);
static int https_fetch(const char *u, char *buf, int max)
{
    char host[URL_MAX], path[URL_MAX];
    int port = 443, n = 0, len;
    const char *p = u + 8;
    while (*p && *p != '/' && *p != ':' && n < URL_MAX - 1) host[n++] = *p++;
    host[n] = 0;
    if (*p == ':') { port = atoi(p + 1); while (*p && *p != '/') p++; }
    copy(path, *p ? p : "/", URL_MAX);
    len = tls_get(host, port, path, buf, max - 1);
    if (len < 0) return -4;
    return parse_answer(buf, len, max);
}

/* an HTTP answer in buf (len bytes, headers first) -> the body moved to
 * buf's start, its length; -3 moved (the address in buf), -2 not 200 */
static int parse_answer(char *buf, int len, int max)
{
    int code, body, i;
    buf[len] = 0;
    if (len < 12 || memcmp(buf, "HTTP/", 5)) return -2;
    code = atoi(buf + 9);
    for (body = 0; body + 3 < len; body++)
        if (buf[body] == '\r' && buf[body + 1] == '\n' && buf[body + 2] == '\r' && buf[body + 3] == '\n') break;
    body += 4;
    if (body > len) body = len;
    if (code >= 300 && code < 400) {                     /* moved: where to */
        for (i = 0; i < body; i++)
            if (buf[i] == '\n' && starts_ci(buf + i + 1, "location:")) {
                const char *l = buf + i + 10;
                char to[URL_MAX];
                int k = 0;
                while (*l == ' ') l++;
                while (*l && *l != '\r' && *l != '\n' && k < URL_MAX - 1) to[k++] = *l++;
                to[k] = 0;
                copy(buf, to, max);
                return -3;
            }
        return -2;
    }
    if (code != 200) return -2;
    {                                                    /* chunked? */
        int chunked = 0;
        for (i = 0; i < body; i++)
            if (buf[i] == '\n' && starts_ci(buf + i + 1, "transfer-encoding:") && starts_ci(buf + i + 20, "chunked"))
                chunked = 1;
        if (!chunked) {
            memmove(buf, buf + body, len - body);
            return len - body;
        }
        {
            int in = body, outp = 0;
            for (;;) {
                int size = 0;
                while (in < len && hexval(buf[in]) >= 0) size = size * 16 + hexval(buf[in++]);
                while (in < len && buf[in] != '\n') in++;
                in++;
                if (size <= 0 || in + size > len) break;
                memmove(buf + outp, buf + in, size);
                outp += size;
                in += size + 2;
            }
            return outp;
        }
    }
}

/* a file (this disk) or a page (http, https) -> buf; its length, or <0 */
static int load(const char *where, char *buf, int max)
{
    int fd, n, tries;
    char u[URL_MAX];
    if (is_http(where)) {
        copy(u, where, URL_MAX);
        for (tries = 0; tries < 4; tries++) {
            n = is_https(u) ? https_fetch(u, buf, max) : fetch(u, buf, max);
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

/* ============================================================
 * downloads: a file (not a page) from the web, straight into
 * /DOWNLOADS as it comes (so as big as a file can be, 4MB), the status
 * line showing how much has come; Esc stops it
 * ============================================================ */
#define DL_LIST 12
#define HDR_MAX 8192
static struct { char name[16]; int size, ok; } dls[DL_LIST];
static int ndls, show_dls;
static char dl_name[16], dl_path[64];
static char dl_hdr[HDR_MAX + 1];
static int dl_hlen, dl_in_body, dl_code, dl_total, dl_written, dl_fd = -1, dl_stop;
static int dl_chunked, dl_chunk_left, dl_chunk_state;  /* 0 size, 1 data, 2 its CRLF, 3 the end */
static char dl_moved[URL_MAX];
static unsigned dl_shown;
static void draw_status(void);
static void redraw(void);

/* a link to a file, not to a page? (by its name's extension) */
static int is_download(const char *u)
{
    static const char *pages[] = { "HTM", "HTML", "MD", "PHP", "ASP", "ASPX", "JSP", "CGI", "SHTML", "TXT", "XHTML", 0 };
    const char *p, *last = u, *ext = 0;
    int i, n;
    if (!is_http(u)) return 0;
    for (p = u + 8; *p && *p != '?' && *p != '#'; p++) if (*p == '/') last = p;
    if (last == u) return 0;                                 /* (just a host) */
    for (p = last; *p && *p != '?' && *p != '#'; p++) if (*p == '.') ext = p + 1;
    if (!ext) return 0;
    n = p - ext;
    if (n < 1 || n > 5) return 0;
    for (i = 0; pages[i]; i++)
        if ((int)strlen(pages[i]) == n && starts_ci(ext, pages[i])) return 0;
    return 1;
}
/* the name to keep it under: the address's last part, as LexOS names
 * are (upper case, 15 at most, the extension kept) */
static void dl_name_of(const char *u, char *out)
{
    const char *p, *last = u, *end;
    char base[16], ext[8];
    int nb = 0, ne = 0, dot = 0;
    for (p = u; *p && *p != '?' && *p != '#'; p++) if (*p == '/') last = p + 1;
    end = p;
    for (p = last; p < end; p++) if (*p == '.') dot = p - last;
    for (p = last; p < end && (dot ? p < last + dot : 1); p++) {
        int c = *p >= 'a' && *p <= 'z' ? *p - 32 : *p;
        if (((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_') && nb < 10) base[nb++] = c;
    }
    if (dot) for (p = last + dot + 1; p < end && ne < 4; p++) {
        int c = *p >= 'a' && *p <= 'z' ? *p - 32 : *p;
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) ext[ne++] = c;
    }
    if (!nb) { memcpy(base, "DOWNLOAD", 8); nb = 8; }
    base[nb] = 0; ext[ne] = 0;
    copy(out, base, 16);
    if (ne) { append(out, ".", 16); append(out, ext, 16); }
}
static void num_kb(char *t, int n, int size)
{
    char d[16];
    int v = (n + 1023) / 1024, i = 15;
    d[i] = 0;
    do { d[--i] = '0' + v % 10; v /= 10; } while (v);
    append(t, d + i, size);
    append(t, " KB", size);
}
/* the status line: how much; Esc stops it */
static void dl_show(void)
{
    int k;
    while ((k = pollkey())) if ((k & 0xFF) == 27) dl_stop = 1;
    if (millis() - dl_shown < 120) return;
    dl_shown = millis();
    copy(status, "Downloading ", sizeof status);
    append(status, dl_name, sizeof status);
    append(status, ": ", sizeof status);
    num_kb(status, dl_written, sizeof status);
    if (dl_total > 0) { append(status, " of ", sizeof status); num_kb(status, dl_total, sizeof status); }
    append(status, "   (Esc stops)", sizeof status);
    draw_status();
    if (dl_total > 0) {
        int w = (int)((double)(W - 16) * dl_written / dl_total);
        if (w > W - 16) w = W - 16;
        if (w > 0) fill(8, H - 3, w, 3, C_LINK, 0, H);
    }
    gfx_blit_rect(frame, 0, H - STATUS, W, STATUS);
}
/* the body's bytes: into the file (opened on the first) */
static void dl_write(const char *d, int n)
{
    if (n <= 0 || dl_stop) return;
    if (dl_fd < 0) {
        dl_fd = open(dl_path, O_WRITE);
        if (dl_fd < 0) { dl_stop = 2; return; }
    }
    if (dl_written + n > 4 * 1024 * 1024) { dl_stop = 3; return; }
    fwrite(dl_fd, d, n);
    dl_written += n;
}
/* a chunked body, a piece at a time */
static void dl_chunks(const char *d, int n)
{
    int i = 0;
    while (i < n && !dl_stop) {
        if (dl_chunk_state == 0) {                             /* its size, in hex */
            int c = d[i++];
            if (hexval(c) >= 0) dl_chunk_left = dl_chunk_left * 16 + hexval(c);
            else if (c == '\n') { dl_chunk_state = dl_chunk_left ? 1 : 3; }
        } else if (dl_chunk_state == 1) {
            int k = n - i < dl_chunk_left ? n - i : dl_chunk_left;
            dl_write(d + i, k);
            i += k;
            dl_chunk_left -= k;
            if (!dl_chunk_left) dl_chunk_state = 2;
        } else if (dl_chunk_state == 2) {                      /* its CRLF */
            if (d[i++] == '\n') { dl_chunk_state = 0; dl_chunk_left = 0; }
        } else i = n;                                          /* the end */
    }
}
/* the answer, as it comes: its headers, then its body */
static int dl_feed(const unsigned char *d, int n)
{
    int i = 0;
    while (!dl_in_body && i < n) {
        if (dl_hlen < HDR_MAX) dl_hdr[dl_hlen++] = d[i];
        i++;
        if (dl_hlen >= 4 && !memcmp(dl_hdr + dl_hlen - 4, "\r\n\r\n", 4)) {
            int j;
            dl_hdr[dl_hlen] = 0;
            dl_in_body = 1;
            dl_code = dl_hlen > 12 && !memcmp(dl_hdr, "HTTP/", 5) ? atoi(dl_hdr + 9) : 0;
            for (j = 0; j < dl_hlen; j++) {
                if (dl_hdr[j] != '\n') continue;
                if (starts_ci(dl_hdr + j + 1, "content-length:")) dl_total = atoi(dl_hdr + j + 16);
                if (starts_ci(dl_hdr + j + 1, "transfer-encoding:") && starts_ci(dl_hdr + j + 20, "chunked")) dl_chunked = 1;
                if (starts_ci(dl_hdr + j + 1, "location:")) {
                    const char *l = dl_hdr + j + 10;
                    int k = 0;
                    while (*l == ' ') l++;
                    while (*l && *l != '\r' && *l != '\n' && k < URL_MAX - 1) dl_moved[k++] = *l++;
                    dl_moved[k] = 0;
                }
            }
            if (dl_code != 200) return 1;                        /* moved, or not there */
        }
    }
    if (i < n) { if (dl_chunked) dl_chunks((const char *)d + i, n - i); else dl_write((const char *)d + i, n - i); }
    dl_show();
    return dl_stop != 0;
}
static int dl_sink(const unsigned char *d, int n) { return dl_feed(d, n); }
/* one try at u: 0 done, 1 moved (dl_moved), -1 failed */
static int dl_get(const char *u)
{
    char host[URL_MAX], path[URL_MAX];
    const char *p = u + (is_https(u) ? 8 : 7);
    int port = is_https(u) ? 443 : 80, n = 0;
    dl_hlen = dl_in_body = dl_code = dl_total = dl_written = dl_chunked = dl_chunk_left = dl_chunk_state = 0;
    dl_moved[0] = 0; dl_shown = 0;
    while (*p && *p != '/' && *p != ':' && n < URL_MAX - 1) host[n++] = *p++;
    host[n] = 0;
    if (*p == ':') { port = atoi(p + 1); while (*p && *p != '/') p++; }
    copy(path, *p ? p : "/", URL_MAX);
    if (is_https(u)) {
        static char none[4];
        tls_sink = dl_sink;
        n = tls_get(host, port, path, none, 0);
        tls_sink = 0;
        if (n < 0 && !dl_in_body) return -1;
    } else {
        char req[URL_MAX * 2 + 120];
        static unsigned char piece[4096];
        if (tcp_open(host, port) < 0) return -1;
        copy(req, "GET ", sizeof req);
        append(req, path, sizeof req);
        append(req, " HTTP/1.0\r\nHost: ", sizeof req);
        append(req, host, sizeof req);
        append(req, "\r\nUser-Agent: LexOS-Web/1.0\r\nConnection: close\r\n\r\n", sizeof req);
        tcp_send(req, strlen(req));
        for (;;) {
            int got = tcp_recv(piece, sizeof piece, 15000);
            if (got <= 0) break;
            if (dl_feed(piece, got)) break;
        }
        tcp_close();
    }
    if (dl_code >= 300 && dl_code < 400 && dl_moved[0]) return 1;
    return dl_code == 200 ? 0 : -1;
}
/* u -> /DOWNLOADS/NAME (NAME1, NAME2... if it's taken) */
static void download(const char *u)
{
    char where[URL_MAX], name[16];
    int r = -1, tries, fd, i;
    copy(where, u, URL_MAX);
    dl_name_of(where, dl_name);
    hover_link = -1;                                              /* (the status line: ours) */
    mkdir("/DOWNLOADS");
    copy(name, dl_name, 16);
    for (i = 1; i < 10; i++) {                                    /* a free name */
        copy(dl_path, "/DOWNLOADS/", sizeof dl_path);
        append(dl_path, name, sizeof dl_path);
        fd = open(dl_path, O_READ);
        if (fd < 0) break;
        close(fd);
        {
            char b[16], e[8];
            int k, dot = -1;
            for (k = 0; dl_name[k]; k++) if (dl_name[k] == '.') dot = k;
            copy(b, dl_name, dot >= 0 && dot < 9 ? dot + 1 : 10);
            copy(e, dot >= 0 ? dl_name + dot : "", 8);
            k = strlen(b);
            b[k] = '0' + i; b[k + 1] = 0;
            copy(name, b, 16);
            append(name, e, 16);
        }
    }
    dl_fd = -1; dl_stop = 0;
    for (tries = 0; tries < 4; tries++) {
        r = dl_get(where);
        if (r != 1) break;
        {
            char moved[URL_MAX];
            resolve(where, dl_moved, moved);
            copy(where, moved, URL_MAX);
        }
        if (!is_http(where)) { r = -1; break; }
    }
    if (dl_fd >= 0) close(dl_fd);
    dl_fd = -1;
    if (r != 0 || dl_stop) {
        copy(status, dl_stop == 1 ? "Download stopped." : dl_stop == 3 ? "Too big: 4MB at most." :
                     dl_stop == 2 ? "Can't write it to /DOWNLOADS." : "The download didn't work.", sizeof status);
        if (dl_written) { fd = open(dl_path, O_WRITE); if (fd >= 0) close(fd); }   /* (a part: emptied) */
        redraw();
        return;
    }
    if (dl_fd < 0 && !dl_written) { fd = open(dl_path, O_WRITE); if (fd >= 0) close(fd); }  /* (an empty file) */
    if (ndls == DL_LIST) { memmove(&dls[0], &dls[1], sizeof dls[0] * (DL_LIST - 1)); ndls--; }
    copy(dls[ndls].name, name, 16);
    dls[ndls].size = dl_written;
    dls[ndls].ok = 1;
    ndls++;
    copy(status, "Saved ", sizeof status);
    append(status, dl_path, sizeof status);
    append(status, " (", sizeof status);
    num_kb(status, dl_written, sizeof status);
    append(status, ")", sizeof status);
    {
        char t[64];
        copy(t, "Downloaded: ", sizeof t);
        append(t, name, sizeof t);
        notify(t);
    }
    redraw();
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
        if (n > 0) pix = n > 8 && (unsigned char)buf[0] == 137 && buf[1] == 'P' ? load_png((unsigned char *)buf, n, &w, &h)
                                                                   : load_bmp(buf, n, &w, &h);
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
    if (!strcmp(name, "code") || !strcmp(name, "tt") || !strcmp(name, "kbd") || !strcmp(name, "samp")) {
        if (closing) { if (ncolor) ncolor--; }
        else if (ncolor < 8) color_stack[ncolor++] = RGB(170, 40, 100);
        return;
    }
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


/* ============================================================
 * Markdown (.MD): turned into HTML first, then laid out as a page -
 * # headings (and === / --- under a line), paragraphs, **bold**,
 * *italic*, `code`, ``` code blocks ``` (and 4-space indented ones),
 * - / * / 1. lists (nested by indent), > quotes, tables, ---,
 * [links](url), ![pictures](x.bmp), <http://...>, and HTML as it is
 * ============================================================ */
static char *mo;
static int mn, mcap;
static void mput(const char *t, int n) { if (n > 0 && mn + n < mcap) { memcpy(mo + mn, t, n); mn += n; } }
static void mputs(const char *t) { mput(t, strlen(t)); }
static void mesc(const char *t, int n)
{
    int i;
    for (i = 0; i < n; i++) {
        if (t[i] == '<') mputs("&lt;");
        else if (t[i] == '>') mputs("&gt;");
        else if (t[i] == '&') mputs("&amp;");
        else if (t[i] == '"') mputs("&quot;");
        else mput(t + i, 1);
    }
}
static int md_alnum(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || (unsigned char)c >= 0x80; }
static int md_punct(int c) { return c > 32 && c < 127 && !md_alnum(c); }

/* t[0..n): a line's (or a paragraph's) text, its inline markup */
static void minline(const char *t, int n)
{
    int i = 0, b = 0, it = 0;
    while (i < n) {
        char c = t[i];
        if (c == '\\' && i + 1 < n && md_punct(t[i + 1])) { mesc(t + i + 1, 1); i += 2; continue; }
        if (c == '`') {                                  /* `code` */
            int k = 0, j, e = -1;
            while (i + k < n && t[i + k] == '`') k++;
            for (j = i + k; j + k <= n; j++) {
                int m = 0;
                while (m < k && t[j + m] == '`') m++;
                if (m == k && (j + k >= n || t[j + k] != '`')) { e = j; break; }
            }
            if (e < 0) { mput(t + i, k); i += k; continue; }
            mputs("<code>");
            mesc(t + i + k, e - i - k);
            mputs("</code>");
            i = e + k;
            continue;
        }
        if ((c == '*' || c == '_') && i + 1 < n && t[i + 1] == c) {   /* **bold** */
            if (c == '_' && i > 0 && md_alnum(t[i - 1]) && b == 0) { mput(t + i, 2); i += 2; continue; }
            mputs(b ? "</b>" : "<b>");
            b = !b;
            i += 2;
            continue;
        }
        if (c == '*' || c == '_') {                      /* *italic* */
            int opening = !it && i + 1 < n && t[i + 1] != ' ';
            int closing = it && i > 0 && t[i - 1] != ' ';
            if (c == '_' && ((i > 0 && md_alnum(t[i - 1]) && !it) || (i + 1 < n && md_alnum(t[i + 1]) && it))) { mput(t + i, 1); i++; continue; }
            if (opening || closing) { mputs(it ? "</i>" : "<i>"); it = !it; i++; continue; }
            mput(t + i, 1);
            i++;
            continue;
        }
        if (c == '~' && i + 1 < n && t[i + 1] == '~') { i += 2; continue; }
        if ((c == '!' && i + 1 < n && t[i + 1] == '[') || c == '[') {   /* [text](url), ![alt](src) */
            int img = c == '!', s0 = i + img + 1, depth = 1, j = s0, e, u0, u1;
            while (j < n && depth) { if (t[j] == '[') depth++; else if (t[j] == ']') depth--; if (depth) j++; }
            if (j < n && j + 1 < n && t[j + 1] == '(') {
                e = j;
                u0 = j + 2;
                u1 = u0;
                depth = 1;
                while (u1 < n && depth) { if (t[u1] == '(') depth++; else if (t[u1] == ')') depth--; if (depth) u1++; }
                if (u1 < n) {
                    int ue = u0;                         /* (url "title") */
                    while (ue < u1 && t[ue] != ' ') ue++;
                    if (img) {
                        mputs("<img src=\"");
                        mesc(t + u0, ue - u0);
                        mputs("\" alt=\"");
                        mesc(t + s0, e - s0);
                        mputs("\">");
                    } else {
                        mputs("<a href=\"");
                        mesc(t + u0, ue - u0);
                        mputs("\">");
                        minline(t + s0, e - s0);
                        mputs("</a>");
                    }
                    i = u1 + 1;
                    continue;
                }
            }
            mput(t + i, 1);
            i++;
            continue;
        }
        if (c == '<') {                                  /* <http://...>, or HTML */
            int j = i + 1;
            if (j < n && (starts_ci(t + j, "http://") || starts_ci(t + j, "https://"))) {
                int e = j;
                while (e < n && t[e] != '>' && t[e] != ' ') e++;
                if (e < n && t[e] == '>') {
                    mputs("<a href=\"");
                    mesc(t + j, e - j);
                    mputs("\">");
                    mesc(t + j, e - j);
                    mputs("</a>");
                    i = e + 1;
                    continue;
                }
            }
            if (j < n && ((t[j] >= 'a' && t[j] <= 'z') || (t[j] >= 'A' && t[j] <= 'Z') || t[j] == '/' || t[j] == '!')) {
                int e = j;
                while (e < n && t[e] != '>') e++;
                if (e < n) { mput(t + i, e + 1 - i); i = e + 1; continue; }
            }
            mputs("&lt;");
            i++;
            continue;
        }
        if (c == '&') {                                  /* &amp; as it is */
            int j = i + 1;
            while (j < n && j - i < 10 && (md_alnum(t[j]) || t[j] == '#')) j++;
            if (j < n && t[j] == ';' && j > i + 1) { mput(t + i, j + 1 - i); i = j + 1; continue; }
            mputs("&amp;");
            i++;
            continue;
        }
        if (c == '>') { mputs("&gt;"); i++; continue; }
        if (c == ' ' && i + 2 < n && t[i + 1] == ' ' && t[i + 2] == '\n') { mputs("<br>"); i += 3; continue; }
        mput(t + i, 1);
        i++;
    }
    if (it) mputs("</i>");
    if (b) mputs("</b>");
}

/* the lines: [ls, le) of line k */
static int strchr_n(const char *s, int n, int c) { int i; for (i = 0; i < n; i++) if (s[i] == c) return 1; return 0; }
static int md_lead(const char *l, int n) { int i = 0; while (i < n && (l[i] == ' ' || l[i] == '\t')) i += 1; return i; }
static int md_blank(const char *l, int n) { return md_lead(l, n) == n; }
static int md_rule(const char *l, int n)
{
    int i, k = 0;
    char c = 0;
    for (i = 0; i < n; i++) {
        if (l[i] == ' ' || l[i] == '\t') continue;
        if (!c) c = l[i];
        if (l[i] != c || (c != '-' && c != '*' && c != '_')) return 0;
        k++;
    }
    return k >= 3;
}
/* a list item? -> the text's start (and *ordered), or -1 */
static int md_item(const char *l, int n, int *ordered)
{
    int i = md_lead(l, n);
    if (i < n && (l[i] == '-' || l[i] == '*' || l[i] == '+') && i + 1 < n && l[i + 1] == ' ') { *ordered = 0; return i + 2; }
    if (i < n && l[i] >= '0' && l[i] <= '9') {
        int j = i;
        while (j < n && l[j] >= '0' && l[j] <= '9') j++;
        if (j < n && (l[j] == '.' || l[j] == ')') && j + 1 < n && l[j + 1] == ' ') { *ordered = 1; return j + 2; }
    }
    return -1;
}
static int md_cells(const char *l, int n, int head)   /* | a | b | */
{
    int i = md_lead(l, n), s;
    if (i < n && l[i] == '|') i++;
    while (n > i && (l[n - 1] == ' ' || l[n - 1] == '|')) n--;
    mputs("<tr>");
    while (i <= n) {
        s = i;
        while (i < n && l[i] != '|') { if (l[i] == '\\') i++; i++; }
        mputs(head ? "<th>" : "<td>");
        while (s < i && l[s] == ' ') s++;
        minline(l + s, i - s);
        mputs(head ? "</th>" : "</td>");
        i++;
    }
    mputs("</tr>\n");
    return 0;
}
static int md_is_sep(const char *l, int n)            /* |---|:--:| */
{
    int i, dash = 0;
    for (i = 0; i < n; i++) {
        if (l[i] == '-') dash++;
        else if (l[i] != '|' && l[i] != ':' && l[i] != ' ') return 0;
    }
    return dash >= 3;
}

static void md_blocks(const char *t, int n)
{
    int p = 0, lists[8], lind[8], nlist = 0, para = -1, pend = 0;
    while (p < n) {
        int e = p, ln, ordered = 0, it;
        const char *l = t + p;
        while (e < n && t[e] != '\n') e++;
        ln = e - p;
        if (ln && l[ln - 1] == '\r') ln--;
#define NEXT (p = e + 1)
#define FLUSH do { if (para >= 0) { mputs("<p>"); minline(t + para, pend - para); mputs("</p>\n"); para = -1; } } while (0)
#define CLOSE_LISTS do { while (nlist) { mputs(lists[--nlist] ? "</ol>\n" : "</ul>\n"); } } while (0)
        if (md_blank(l, ln)) {
            FLUSH;
            /* a list goes on past a blank line only if what follows is its */
            if (nlist) {
                int q = e + 1, qe, o2;
                while (q < n) { qe = q; while (qe < n && t[qe] != '\n') qe++; if (!md_blank(t + q, qe - q)) break; q = qe + 1; }
                if (q >= n || (md_item(t + q, n - q, &o2) < 0 && md_lead(t + q, n - q) < 2)) CLOSE_LISTS;
            }
            NEXT;
            continue;
        }
        {                                               /* ``` fenced code ``` */
            int i = md_lead(l, ln);
            if (i + 2 < ln && ((l[i] == '`' && l[i + 1] == '`' && l[i + 2] == '`') || (l[i] == '~' && l[i + 1] == '~' && l[i + 2] == '~'))) {
                char f = l[i];
                FLUSH;
                CLOSE_LISTS;
                mputs("<pre>");
                NEXT;
                while (p < n) {
                    int e2 = p, l2, j;
                    while (e2 < n && t[e2] != '\n') e2++;
                    l2 = e2 - p;
                    if (l2 && t[p + l2 - 1] == '\r') l2--;
                    j = md_lead(t + p, l2);
                    if (j + 2 < l2 + 1 && l2 - j >= 3 && t[p + j] == f && t[p + j + 1] == f && t[p + j + 2] == f) { p = e2 + 1; break; }
                    mesc(t + p, l2);
                    mputs("\n");
                    p = e2 + 1;
                }
                mputs("</pre>\n");
                continue;
            }
        }
        if (l[md_lead(l, ln)] == '#') {                  /* # a heading */
            int i = md_lead(l, ln), h = 0, s0, s1;
            while (i < ln && l[i] == '#' && h < 7) { i++; h++; }
            if (h <= 6 && (i == ln || l[i] == ' ')) {
                char tagn[8] = "<h1>";
                FLUSH;
                CLOSE_LISTS;
                while (i < ln && l[i] == ' ') i++;
                s0 = i;
                s1 = ln;
                while (s1 > s0 && (l[s1 - 1] == '#' || l[s1 - 1] == ' ')) s1--;
                tagn[2] = '0' + h;
                mputs(tagn);
                minline(l + s0, s1 - s0);
                tagn[1] = '/'; tagn[2] = 'h'; tagn[3] = '0' + h; tagn[4] = '>'; tagn[5] = 0;
                mputs(tagn);
                mputs("\n");
                NEXT;
                continue;
            }
        }
        /* === / --- under a paragraph's one line: a heading */
        if (para >= 0 && ln >= 2 && md_lead(l, ln) < 4) {
            int i = md_lead(l, ln), k = i;
            char c = l[i];
            while (k < ln && l[k] == c) k++;
            while (k < ln && l[k] == ' ') k++;
            if ((c == '=' || c == '-') && k == ln && k - i >= 2) {
                mputs(c == '=' ? "<h1>" : "<h2>");
                minline(t + para, pend - para);
                mputs(c == '=' ? "</h1>\n" : "</h2>\n");
                para = -1;
                NEXT;
                continue;
            }
        }
        if (md_rule(l, ln)) { FLUSH; CLOSE_LISTS; mputs("<hr>\n"); NEXT; continue; }
        if (l[md_lead(l, ln)] == '>') {                  /* > a quote: its lines, again */
            int q = p, qn = 0;
            char *sub = malloc(n - p + 1);
            FLUSH;
            CLOSE_LISTS;
            if (!sub) { NEXT; continue; }
            while (q < n) {
                int qe = q, j;
                while (qe < n && t[qe] != '\n') qe++;
                j = md_lead(t + q, qe - q);
                if (q + j >= qe || t[q + j] != '>') break;
                j++;
                if (q + j < qe && t[q + j] == ' ') j++;
                memcpy(sub + qn, t + q + j, qe - q - j);
                qn += qe - q - j;
                sub[qn++] = '\n';
                q = qe + 1;
            }
            mputs("<blockquote>");
            md_blocks(sub, qn);
            mputs("</blockquote>\n");
            free(sub);
            p = q;
            continue;
        }
        if (strchr_n(l, ln, '|') && e + 1 < n) {         /* a table */
            int e2 = e + 1, l2;
            while (e2 < n && t[e2] != '\n') e2++;
            l2 = e2 - e - 1;
            if (md_is_sep(t + e + 1, l2) && strchr_n(t + e + 1, l2, '-')) {
                FLUSH;
                CLOSE_LISTS;
                mputs("<table>");
                md_cells(l, ln, 1);
                p = e2 + 1;
                while (p < n) {
                    int e3 = p;
                    while (e3 < n && t[e3] != '\n') e3++;
                    if (md_blank(t + p, e3 - p) || !strchr_n(t + p, e3 - p, '|')) break;
                    md_cells(t + p, e3 - p - (e3 > p && t[e3 - 1] == '\r'), 0);
                    p = e3 + 1;
                }
                mputs("</table>\n");
                continue;
            }
        }
        it = md_item(l, ln, &ordered);
        if (it >= 0) {                                   /* - an item */
            int ind = md_lead(l, ln);
            FLUSH;
            while (nlist && ind < lind[nlist - 1]) mputs(lists[--nlist] ? "</ol>\n" : "</ul>\n");
            if (nlist && ind == lind[nlist - 1] && lists[nlist - 1] != ordered) mputs(lists[--nlist] ? "</ol>\n" : "</ul>\n");
            if ((!nlist || ind > lind[nlist - 1]) && nlist < 8) {
                lists[nlist] = ordered;
                lind[nlist++] = ind;
                mputs(ordered ? "<ol>" : "<ul>");
            }
            mputs("<li>");
            minline(l + it, ln - it);
            mputs("\n");
            NEXT;
            continue;
        }
        if (nlist && md_lead(l, ln) >= 2 && para < 0) {  /* an item's next line */
            mputs(" ");
            minline(l + md_lead(l, ln), ln - md_lead(l, ln));
            mputs("\n");
            NEXT;
            continue;
        }
        if (para < 0 && md_lead(l, ln) >= 4 && !nlist) { /* indented code */
            mputs("<pre>");
            while (p < n) {
                int e2 = p, l2;
                while (e2 < n && t[e2] != '\n') e2++;
                l2 = e2 - p;
                if (l2 && t[p + l2 - 1] == '\r') l2--;
                if (!md_blank(t + p, l2) && md_lead(t + p, l2) < 4) break;
                if (l2 > 4) mesc(t + p + 4, l2 - 4);
                mputs("\n");
                p = e2 + 1;
            }
            mputs("</pre>\n");
            continue;
        }
        if (l[md_lead(l, ln)] == '<' && para < 0) {      /* HTML as it is */
            CLOSE_LISTS;
            mput(l, ln);
            mputs("\n");
            NEXT;
            continue;
        }
        if (nlist) CLOSE_LISTS;
        if (para < 0) para = p + md_lead(l, ln);         /* a paragraph's line */
        pend = p + ln;
        NEXT;
    }
    FLUSH;
    CLOSE_LISTS;
#undef NEXT
#undef FLUSH
#undef CLOSE_LISTS
}

/* src[0..srclen): Markdown -> HTML, in its place */
static void markdown(void)
{
    mcap = srclen * 3 + 8192;
    mo = malloc(mcap);
    if (!mo) return;
    mn = 0;
    mputs("<html><body>");
    md_blocks(src, srclen);
    mputs("</body></html>");
    if (mn > SRC_MAX) mn = SRC_MAX;
    memcpy(src, mo, mn);
    srclen = mn;
    free(mo);
}
static int is_markdown(const char *u)
{
    int l = 0;
    while (u[l] && u[l] != '?' && u[l] != '#') l++;
    return (l > 3 && starts_ci(u + l - 3, ".md")) || (l > 9 && starts_ci(u + l - 9, ".markdown"));
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
#define BTN_Y (BAR_Y + 6)
#define BTN_H 24
static const int btn_x[] = { 8, 38, 68, 98 };
#define ADDR_X 132
#define GO_X (W - 78)
#define DL_X (W - 36)
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
    fill(0, BAR_Y, W, BAR, C_BAR, 0, H);
    fill(0, BAR_Y + BAR - 1, W, 1, C_BAR_LO, 0, H);
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
        if (editing && edit_fresh && *t) {               /* chosen: lit */
            fill(ADDR_X + 6, BTN_Y + 4, (int)strlen(t) * 8 + 2, 16, C_LINK, 0, H);
            text_at(ADDR_X + 7, BTN_Y + 4, t, C_PAGE, 0, ADDR_W - 12);
        } else
            text_at(ADDR_X + 7, BTN_Y + 4, t, C_TEXT, 0, ADDR_W - 12);
        if (editing) fill(ADDR_X + 7 + (int)strlen(t) * 8, BTN_Y + 4, 2, 16, C_LINK, 0, H);
    }
    if (!editing && is_https(url)) {                     /* encrypted: said */
        fill(ADDR_X + ADDR_W - 44, BTN_Y + 4, 38, 16, RGB(40, 150, 70), 0, H);
        text_at(ADDR_X + ADDR_W - 41, BTN_Y + 4, "TLS", RGB(255, 255, 255), ST_BOLD, 32);
    }
    bevel(GO_X, BTN_Y, 36, BTN_H, hover_btn == 4 ? C_HOVER : C_BTN);
    text_at(GO_X + 10, BTN_Y + 4, "Go", C_TEXT, ST_BOLD, 24);
    bevel(DL_X, BTN_Y, 28, BTN_H, show_dls ? C_LINK : hover_btn == 6 ? C_HOVER : C_BTN);
    text_at(DL_X + 10, BTN_Y + 4, "\x19", show_dls ? C_PAGE : C_TEXT, ST_BOLD, 16);
}

/* the downloads, over the page's top right */
static void draw_downloads(void)
{
    int i, bw = 320, bh = 44 + (ndls ? ndls : 1) * 20, bx = W - SBW - bw - 6, by = VIEW_Y + 4;
    fill(bx + 3, by + 3, bw, bh, RGB(150, 156, 170), 0, H);
    fill(bx, by, bw, bh, C_BAR_LO, 0, H);
    fill(bx + 1, by + 1, bw - 2, bh - 2, C_PAGE, 0, H);
    text_at(bx + 10, by + 6, "Downloads (in /DOWNLOADS)", C_HEAD, ST_BOLD, bw - 20);
    if (!ndls) text_at(bx + 10, by + 28, "None yet: a link to a file saves it.", C_GRAY, 0, bw - 20);
    for (i = 0; i < ndls; i++) {
        char t[32];
        t[0] = 0;
        num_kb(t, dls[i].size, sizeof t);
        text_at(bx + 10, by + 28 + i * 20, dls[i].name, C_TEXT, 0, 150);
        text_at(bx + bw - 10 - 8 * (int)strlen(t), by + 28 + i * 20, t, C_GRAY, 0, 100);
    }
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

/* ============================================================
 * the tabs
 * ============================================================ */
static int tab_w(void) { int w = (W - 44) / ntabs; return w > 190 ? 190 : w; }
static const char *tab_label(int i)
{
    const char *t = i == cur_tab ? (title[0] ? title : url) : (tabs[i].title[0] ? tabs[i].title : tabs[i].url);
    const char *b = t;
    if (t != title && t != tabs[i].title) {            /* an address: its last part */
        const char *q;
        for (q = t; *q; q++) if (*q == '/' && q[1]) b = q + 1;
    }
    return *b ? b : "New tab";
}
static void draw_tabs(void)
{
    int i, w = tab_w();
    fill(0, 0, W, TABS_H, C_BAR_LO, 0, H);
    for (i = 0; i < ntabs; i++) {
        int x = 4 + i * w, on = i == cur_tab;
        unsigned face = on ? C_BAR : hover_tab == i ? C_HOVER : RGB(200, 208, 222);
        fill(x, 4, w - 3, TABS_H - 4, face, 0, H);
        if (on) fill(x, 4, w - 3, 2, C_LINK, 0, H);
        text_at(x + 8, 9, tab_label(i), on ? C_TEXT : C_GRAY, on ? ST_BOLD : 0, w - 34);
        if (ntabs > 1)
            text_at(x + w - 20, 8, "x", hover_close == i ? RGB(200, 40, 60) : C_GRAY, ST_BOLD, 10);
    }
    i = 4 + ntabs * w;                                   /* + */
    if (ntabs < TABS_MAX) {
        fill(i + 2, 6, 24, TABS_H - 8, hover_tab == 100 ? C_HOVER : RGB(200, 208, 222), 0, H);
        text_at(i + 10, 8, "+", C_TEXT, ST_BOLD, 10);
    }
}
/* the pointer over the tabs -> the tab (100: +), *close set if on its x */
static int tab_at(int mx, int my, int *close)
{
    int w = tab_w(), i;
    *close = 0;
    if (my >= TABS_H || my < 4) return -1;
    i = (mx - 4) / w;
    if (mx >= 4 && i < ntabs) {
        if (ntabs > 1 && mx >= 4 + i * w + w - 24 && mx < 4 + i * w + w - 6) *close = 1;
        return i;
    }
    if (ntabs < TABS_MAX && mx >= 6 + ntabs * w && mx < 30 + ntabs * w) return 100;
    return -1;
}

static void go(const char *to, int remember);
static void clamp_scroll(void);
static void layout(void);
/* the one in front, into its tab */
static void tab_save(void)
{
    struct tab *t = &tabs[cur_tab];
    copy(t->url, url, URL_MAX);
    memcpy(t->hist, hist, sizeof hist);
    t->nhist = nhist; t->hpos = hpos; t->scroll = scroll;
    copy(t->title, title, sizeof t->title);
    free(t->src);
    t->src = malloc(srclen + 1);
    if (t->src) { memcpy(t->src, src, srclen); t->srclen = srclen; }
}
/* tab i to the front: its page back - kept, or read again */
static void tab_show(int i)
{
    struct tab *t = &tabs[i];
    cur_tab = i;
    copy(url, t->url, URL_MAX);
    memcpy(hist, t->hist, sizeof hist);
    nhist = t->nhist; hpos = t->hpos;
    editing = 0; hover_link = -1;
    if (t->src) {
        memcpy(src, t->src, t->srclen);
        srclen = t->srclen;
        src[srclen] = 0;
        free(t->src); t->src = 0;
        layout();
        scroll = t->scroll;
        clamp_scroll();
        status[0] = 0;
    } else if (url[0]) {
        int sc = t->scroll;
        go(url, 0);
        scroll = sc;
        clamp_scroll();
    }
}
static void tab_new(const char *to)
{
    if (ntabs >= TABS_MAX) return;
    tab_save();
    memset(&tabs[ntabs], 0, sizeof tabs[0]);
    cur_tab = ntabs++;
    url[0] = 0; nhist = 0; hpos = -1; scroll = 0; title[0] = 0;
    go(to, 1);
}
static void tab_close(int i)
{
    int j;
    if (ntabs < 2) return;
    if (i != cur_tab) {                                  /* one behind: just gone */
        free(tabs[i].src);
        for (j = i; j < ntabs - 1; j++) tabs[j] = tabs[j + 1];
        ntabs--;
        if (cur_tab > i) cur_tab--;
        return;
    }
    free(tabs[i].src);
    for (j = i; j < ntabs - 1; j++) tabs[j] = tabs[j + 1];
    ntabs--;
    tab_show(i < ntabs ? i : ntabs - 1);
}
static void tab_go(int i)
{
    if (i == cur_tab || i < 0 || i >= ntabs) return;
    tab_save();
    tab_show(i);
}

static void redraw(void)
{
    draw_tabs();
    draw_bar();
    draw_page();
    if (show_dls) draw_downloads();
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
                            "/DEMOS/SITE/INDEX.HTM</a>) or on the web, over <b>http://</b> or "
                            "<b>https://</b>.</p>", 0 };
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
    if (!is_http(where) && where[0] != '/' &&
        (starts_ci(where, "www.") || (strlen(where) > 4 && !starts_ci(where + strlen(where) - 4, ".htm") &&
                                     !starts_ci(where + strlen(where) - 5, ".html")))) {
        char t[URL_MAX];                  /* "example.com" -> http:// */
        copy(t, "https://", URL_MAX);
        append(t, where, URL_MAX);
        copy(where, t, URL_MAX);
    }
    if (is_download(where)) { download(where); return; }
    copy(url, where, URL_MAX);
    copy(status, "Loading ", sizeof status);
    append(status, where, sizeof status);
    append(status, " ...", sizeof status);
    hover_link = -1;
    redraw();
    {
        n = load(where, src, SRC_MAX);
        if (n >= 0) srclen = n;
        else if (n == -4) {
            static char why[200];
            copy(why, "The encrypted connection (TLS 1.3) didn't work: ", sizeof why);
            append(why, tls_error, sizeof why);
            error_page(why, where);
        } else error_page(n == -2 ? "The server answered, but not with the page (not found, or not allowed)."
                                  : is_http(where) ? "No answer - is the network up? (ifconfig, dhcp)"
                                                   : "There's no such file on this disk.", where);
    }
    src[srclen] = 0;
    if (is_markdown(where)) { markdown(); src[srclen] = 0; }
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
    if (mx >= DL_X && mx < DL_X + 28) return 6;
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
    else if (b == 5 && !editing) { editing = 1; edit_fresh = 1; copy(edit_url, url, URL_MAX); redraw(); }
    else if (b == 6) { show_dls = !show_dls; redraw(); }
}

int main(int argc, char **argv)
{
    int m[4], was_down = 0, drag = -1, drag_scroll = 0;
    if (gfx_mode_ex(W, H, 32) < 0) { puts("browser: needs 800x600 in 32 bits\n"); return 1; }
    font(glyphs);
    keymode(1);                                          /* (Ctrl+T, W, Tab: ours) */
    go(argc > 1 ? argv[1] : home, 1);
    for (;;) {
        int k = pollkey(), changed = 0, over;
        {                                                /* a page opened in Files */
            char in[URL_MAX];                            /* while we're open: a tab */
            if (inbox(in, sizeof in) > 0) { if (ntabs < TABS_MAX) tab_new(in); else go(in, 1); changed = 1; }
        }
        if (k) {
            int ch = k & 0xFF, sc = (k >> 8) & 0xFF;
            if (editing) {
                int l = strlen(edit_url);
                if (ch == 13) { editing = 0; go(edit_url, 1); }
                else if (ch == 27) editing = 0;
                else if (ch == 8) { if (edit_fresh) edit_url[0] = 0; else if (l) edit_url[l - 1] = 0; edit_fresh = 0; }
                else if (ch >= 32 && ch < 127 && l < URL_MAX - 1) {
                    if (edit_fresh) { l = 0; edit_fresh = 0; }   /* (all chosen: replaced) */
                    edit_url[l] = ch;
                    edit_url[l + 1] = 0;
                }
                changed = 1;
            } else if (ch == 27) break;
            else if (ch == 20) { tab_new(home); continue; }                 /* Ctrl+T */
            else if (ch == 19) {                                            /* Ctrl+S: this page, kept */
                if (is_http(url)) download(url);
                else { copy(status, "It's on this disk already.", sizeof status); changed = 1; }
            }
            else if (ch == 23) { tab_close(cur_tab); changed = 1; }         /* Ctrl+W */
            else if (ch == 9 && keydown(KEY_CTRL)) { tab_go((cur_tab + 1) % ntabs); changed = 1; }
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
            int on_x, ht = tab_at(mx, my, &on_x), hx = on_x ? ht : -1;
            if (hl != hover_link || hb != hover_btn) { hover_link = hl; hover_btn = hb; changed = 1; }
            if (ht != hover_tab || hx != hover_close) { hover_tab = ht; hover_close = hx; changed = 1; }
            if (down && !was_down && ht >= 0) {                     /* the tabs */
                if (ht == 100) { tab_new(home); was_down = down; continue; }
                if (on_x) tab_close(ht); else tab_go(ht);
                changed = 1;
            } else if (down && !was_down) {
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
                    if (keydown(KEY_CTRL)) tab_new(to);             /* Ctrl: a new tab */
                    else go(to, 1);
                    was_down = down;
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
