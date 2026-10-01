/* browser.c - LexOS Web: a web browser in a window.
 *
 *   run browser.app [address]
 *
 * Opens pages from LexOS's own disk (/DEMOS/SITE/INDEX.HTM - the start
 * page) or from the web over plain http:// (its own HTTP/1.1 on the
 * kernel's TCP: tcp_open() and the rest). It knows the HTML a simple
 * page needs: headings, paragraphs, line breaks, bold/italic/underlined
 * text, links, lists (bullets and numbers), <pre>, <hr>, <blockquote>, <center>,
 * tables as grids, <font color>, <body bgcolor>, and pictures -
 * <img> of .BMP (8, 24 or 32 bits), .PNG (png.h), .JPG (jpeg.h) and
 * .GIF (gif.h), up to 64 a page. Text is shown in LexOS's font (Russian
 * and Spanish letters too, the rest as near as it can be).
 *
 * So that no page comes out as gibberish: gzip'd or deflated pages are
 * unpacked (inflate.h); the charset is the server's, the <meta>'s, a
 * BOM's, or guessed from the bytes (UTF-8, windows-1251, KOI8-R, CP866,
 * ISO-8859-5, windows-1252). A page is stripped as it comes (scripts,
 * SVG, comments, most attributes left out) and kept whole, however big:
 * past the program's own 4MB, malloc gets the kernel's extra memory.
 * A little CSS (css.h): what's hidden stays hidden; bold, italic,
 * colors, centering, the background. JSON and text are shown as text,
 * a picture as a picture, the rest is offered as a download.
 * Pictures and style sheets are kept in /TMP/WEB (the cache: F5 reads
 * past it).
 *
 * Reader mode (Aa, F9): the article alone. Ctrl+I: about this page.
 * Ctrl+U: its source, in a new tab.
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
 * saves it in /DOWNLOADS as it comes, any size (the disk's FAT32
 * writes it in place), the status line counting (Esc
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
#include "jpeg.h"                        /* ... .JPG */
#include "gif.h"                         /* ... .GIF */
#include "inflate.h"                     /* pages sent gzip'd */
#include "css.h"                         /* the little CSS it knows */

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
#define RIGHT right_x                     /* the text's right edge (the reader: narrower) */
static int left_x = MARGIN, right_x = W - SBW - MARGIN;

/* the page and what's laid out of it: as big as they need to be (the
 * memory's lexos.h's malloc - past the program's own 4MB, the kernel's
 * extra memory), up to these */
#define SRC_MAX (48 * 1024 * 1024)
#define ITEMS_MAX (1024 * 1024)           /* (words run together: a line's worth each) */
#define POOL_MAX (32 * 1024 * 1024)
#define LINKS_MAX (256 * 1024)
#define LPOOL_MAX (16 * 1024 * 1024)
#define ZBUF_MAX (32 * 1024 * 1024)
#define URL_MAX 1024
#define HIST_MAX 24

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
static char *src;
static int srclen, src_cap;

/* *buf (cap elements of size each) made room for need of them (doubled,
 * up to max): 1, or 0 if there's no memory for it */
static int grow(void *buf, int *cap, int need, int size, int max)
{
    void **b = (void **)buf;
    int want = *cap ? *cap : 1024;
    void *nb;
    if (need <= *cap) return 1;
    if (need > max) return 0;
    while (want < need) want = want > max / 2 ? max : want * 2;
    nb = realloc(*b, (size_t)want * size + 1);
    if (!nb) {
        want = need;                                     /* (just enough, then) */
        nb = realloc(*b, (size_t)want * size + 1);
        if (!nb) return 0;
    }
    *b = nb;
    *cap = want;
    return 1;
}
#define SRC_ROOM(n) grow(&src, &src_cap, (n) + 1, 1, SRC_MAX)

/* --- what's on the page: a list of items, laid out --- */
enum { IT_TEXT, IT_RULE, IT_IMAGE, IT_BOX, IT_CTRL };
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
static struct item *items;
static int nitems, items_cap;
static char *pool;
static int npool, pool_cap;
static int *link_off;
static int nlinks, links_cap;
static char *lpool;
static int nlpool, lpool_cap;
#define POOL_ROOM(n) grow(&pool, &pool_cap, npool + (n), 1, POOL_MAX)
static unsigned page_bg;
static int doc_h, scroll;
static char title[80];
static int view_source, reader;                          /* (the page's source; the reader) */

/* --- where we are --- */
static char url[URL_MAX], edit_url[URL_MAX];
static char hist[HIST_MAX][URL_MAX];
static int nhist, hpos = -1;
static int editing, edit_fresh, hover_link = -1, hover_btn = -1, hover_ctrl = -1;
static char *post_body;                   /* a form POSTed: the next page's request */
static int post_len, post_now;
static void ck_set(const char *h);
static void ck_save(void);
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
    int srclen, kind, cs, vs;
    void *css;                            /* (its rules: css_save) */
    char base[URL_MAX];
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
    if (u >= 0x100 && u <= 0x17F) {                     /* Latin Extended-A: the letter */
        static const char ext[] = "AaAaAaCcCcCcCcDdDdEeEeEeEeEeGgGgGgGgHhHhIiIiIiIiIiJjJjKkkLlLlLlLlLlNnNnNnnNnOoOoOoOoRrRrRrSsSsSsSsTtTtTtUuUuUuUuUuUuWwYyYZzZzZzs";
        out[0] = u == 0x152 ? 'O' : u == 0x153 ? 'o' : ext[u - 0x100];
        if (u == 0x152 || u == 0x153) { out[1] = u == 0x152 ? 'E' : 'e'; return 2; }
        return 1;
    }
    /* nothing to see: joiners, marks of direction, soft hyphens, the
     * byte order mark, emoji's variation selectors and skin tones */
    if ((u >= 0x200B && u <= 0x200F) || (u >= 0x2060 && u <= 0x2064) || u == 0xFEFF || u == 0xAD ||
        (u >= 0xFE00 && u <= 0xFE0F) || (u >= 0x1F3FB && u <= 0x1F3FF) || u == 0x34F) return 0;
    if ((u >= 0x2000 && u <= 0x200A) || u == 0x202F || u == 0x205F || u == 0x3000 || u == 0x2028 || u == 0x2029) { out[0] = ' '; return 1; }
    /* icon fonts' private letters (Font Awesome and such: a picture we
     * haven't got), accents put on top of a letter, flags' letters,
     * the keycap's frame: nothing */
    if ((u >= 0xE000 && u <= 0xF8FF) || (u >= 0xF0000 && u < 0xF0080) || (u > 0xF00FF && u <= 0x10FFFF) ||
        (u >= 0x300 && u <= 0x36F) || (u >= 0x1AB0 && u <= 0x1AFF) || (u >= 0x20D0 && u <= 0x20FF) ||
        (u >= 0x1F1E6 && u <= 0x1F1FF) || (u >= 0xE0000 && u <= 0xE007F)) return 0;
    if (u >= 0xFF01 && u <= 0xFF5E) { out[0] = (char)(u - 0xFF01 + '!'); return 1; }       /* fullwidth */
    if ((u >= 0x1D400 && u <= 0x1D6A3)) {                /* math's bold/italic letters: the letter */
        int k = (u - 0x1D400) % 52;
        out[0] = k < 26 ? 'A' + k : 'a' + k - 26;
        return 1;
    }
    if (u >= 0x1D7CE && u <= 0x1D7FF) { out[0] = '0' + (u - 0x1D7CE) % 10; return 1; }
    if (u >= 0x391 && u <= 0x3C9) {                      /* Greek: the nearest Latin */
        static const char gr[] = "ABGDEZHOIKLMNXOPRSSTYFXPW" "IYaehiy" "abgdezhoiklmnxoprsstyfxpw";
        if (u == 0x3C0) { out[0] = 'p'; out[1] = 'i'; return 2; }
        out[0] = gr[u - 0x391];
        return 1;
    }
    if (u >= 0x1F600 && u <= 0x1F64F) {                   /* faces */
        out[0] = ':';
        out[1] = (u >= 0x1F61E && u <= 0x1F62D) || u == 0x1F641 || u == 0x1F616 || u == 0x1F614 ? '(' : ')';
        return 2;
    }
    if (u == 0x1F44D) { out[0] = '+'; out[1] = '1'; return 2; }
    if (u == 0x1F525) { out[0] = '!'; return 1; }
    {                                                    /* as themselves, or near it */
        static const struct { unsigned u; char t[4]; } near[] = {
            { 0x2116, "No" }, { 0x20AC, "EUR" }, { 0xA3, "L" }, { 0xA5, "Y" }, { 0xA2, "c" }, { 0x20BD, "RUB" },
            { 0x2122, "TM" }, { 0xAE, "(R)" }, { 0xD7, "x" }, { 0xF7, "/" }, { 0xB1, "+-" }, { 0x2248, "~" },
            { 0x2260, "!=" }, { 0x2264, "<=" }, { 0x2265, ">=" }, { 0x221E, "oo" }, { 0x2030, "%o" },
            { 0xBD, "1/2" }, { 0xBC, "1/4" }, { 0xBE, "3/4" }, { 0xB2, "2" }, { 0xB3, "3" }, { 0xB9, "1" },
            { 0x2032, "'" }, { 0x2033, "\"" }, { 0x201A, "," }, { 0x201E, "\"" }, { 0x2039, "<" }, { 0x203A, ">" },
            { 0x2020, "+" }, { 0x2021, "+" }, { 0xB5, "u" }, { 0x2010, "-" }, { 0x2011, "-" }, { 0x2012, "-" },
            { 0x2015, "-" }, { 0x2043, "-" }, { 0x2BC, "'" }, { 0x2B9, "'" }, { 0xB4, "'" }, { 0x2DC, "~" },
            { 0x2C6, "^" }, { 0x192, "f" }, { 0x2717, "x" }, { 0x2718, "x" }, { 0x274C, "x" }, { 0x2716, "x" },
            { 0x2605, "*" }, { 0x2606, "*" }, { 0x2B50, "*" }, { 0x2027, "-" }, { 0x2044, "/" }, { 0x2215, "/" },
            { 0x2191, "\x18" }, { 0x2193, "\x19" }, { 0x2194, "\x1d" }, { 0x2195, "\x12" }, { 0x21D2, "=>" },
            { 0x21D0, "<=" }, { 0x25B2, "\x1e" }, { 0x25B4, "\x1e" }, { 0x25BC, "\x1f" }, { 0x25BE, "\x1f" },
            { 0x25B6, "\x10" }, { 0x25BA, "\x10" }, { 0x25B8, "\x10" }, { 0x25C0, "\x11" }, { 0x25C4, "\x11" },
            { 0x2665, "\x03" }, { 0x2764, "\x03" }, { 0x2666, "\x04" }, { 0x2663, "\x05" }, { 0x2660, "\x06" },
            { 0x263A, "\x01" }, { 0x263B, "\x02" }, { 0x266A, "\x0d" }, { 0x266B, "\x0e" }, { 0x25CB, "\x09" },
            { 0x25CF, "\x07" }, { 0x221A, "\xfb" }, { 0x2713, "\xfb" }, { 0x2714, "\xfb" }, { 0x2705, "\xfb" },
            { 0xB6, "\x14" }, { 0xA7, "\x15" }, { 0x203C, "\x13" }, { 0x25A0, "\xfe" }, { 0x25AA, "\xfe" },
            { 0x2500, "\xc4" }, { 0x2502, "\xb3" }, { 0x250C, "\xda" }, { 0x2510, "\xbf" }, { 0x2514, "\xc0" },
            { 0x2518, "\xd9" }, { 0x251C, "\xc3" }, { 0x2524, "\xb4" }, { 0x252C, "\xc2" }, { 0x2534, "\xc1" },
            { 0x253C, "\xc5" }, { 0x2550, "\xcd" }, { 0x2551, "\xba" }, { 0x2554, "\xc9" }, { 0x2557, "\xbb" },
            { 0x255A, "\xc8" }, { 0x255D, "\xbc" }, { 0x2560, "\xcc" }, { 0x2563, "\xb9" }, { 0x2566, "\xcb" },
            { 0x2569, "\xca" }, { 0x256C, "\xce" }, { 0x2580, "\xdf" }, { 0x2584, "\xdc" }, { 0x2588, "\xdb" },
            { 0x258C, "\xdd" }, { 0x2590, "\xde" }, { 0x2591, "\xb0" }, { 0x2592, "\xb1" }, { 0x2593, "\xb2" },
            { 0x40E, "Y" }, { 0x45E, "y" }, { 0x406, "I" }, { 0x407, "I" }, { 0x404, "E" }, { 0x490, "G" },
            { 0x402, "D" }, { 0x452, "d" }, { 0x403, "G" }, { 0x453, "g" }, { 0x409, "Lj" }, { 0x459, "lj" },
            { 0x40A, "Nj" }, { 0x45A, "nj" }, { 0x40B, "C" }, { 0x45B, "c" }, { 0x40C, "K" }, { 0x45C, "k" },
            { 0x2122, "TM" }, { 0x2120, "SM" }, { 0x2103, "C" }, { 0x2109, "F" }, { 0x2153, "1/3" }, { 0x2154, "2/3" },
            { 0x215B, "1/8" }, { 0x2070, "0" }, { 0x2074, "4" }, { 0x2075, "5" }, { 0x2076, "6" }, { 0x2077, "7" },
            { 0x2078, "8" }, { 0x2079, "9" }, { 0x207A, "+" }, { 0x207B, "-" }, { 0x2080, "0" }, { 0x2081, "1" },
            { 0x2082, "2" }, { 0x2083, "3" }, { 0x2084, "4" }, { 0x2196, "\\" }, { 0x2197, "/" }, { 0x2198, "\\" },
            { 0x2199, "/" }, { 0x21A9, "<-" }, { 0x21AA, "->" }, { 0x21BA, "@" }, { 0x21BB, "@" }, { 0x21C4, "<>" },
            { 0x21E7, "\x18" }, { 0x2B06, "\x18" }, { 0x2B07, "\x19" }, { 0x2B05, "\x1b" }, { 0x27A1, "\x1a" },
            { 0x2794, "\x1a" }, { 0x279C, "\x1a" }, { 0x27F6, "->" }, { 0x27F5, "<-" }, { 0x2303, "^" }, { 0x2318, "#" },
            { 0x2325, "Alt" }, { 0x21B5, "<-" }, { 0x23CE, "<-" }, { 0x2302, "\x7f" }, { 0x2261, "=" },
            { 0x2630, "=" }, { 0x22EE, ":" }, { 0x22EF, "..." }, { 0x2219, "\x07" }, { 0x22C5, "." },
             { 0x25E6, "o" }, { 0x2043, "-" }, { 0x2981, "\x07" }, { 0x26AB, "\x07" },
            { 0x26AA, "o" }, { 0x2B24, "\x07" }, { 0x25FC, "\xfe" }, { 0x25FE, "\xfe" }, { 0x2B1B, "\xfe" },
            { 0x2610, "[ ]" }, { 0x2611, "[x]" }, { 0x2612, "[x]" }, { 0x2715, "x" }, { 0x2A2F, "x" }, { 0x2295, "(+)" },
            { 0x2207, "V" }, { 0x2206, "D" }, { 0x2211, "E" }, { 0x220F, "P" }, { 0x222B, "S" }, { 0x2202, "d" },
            { 0x2208, "E" }, { 0x2205, "0" }, { 0x2229, "n" }, { 0x222A, "U" }, { 0x2227, "^" }, { 0x2228, "v" },
            { 0x2200, "A" }, { 0x2203, "E" }, { 0x2192, "\x1a" }, { 0x2261, "=" }, { 0x2245, "~=" }, { 0x221D, "~" },
            { 0x2032, "'" }, { 0x2116, "No" }, { 0x20B4, "UAH" }, { 0x20B8, "KZT" }, { 0x20BA, "TL" }, { 0x20B9, "Rs" },
            { 0x20A9, "W" }, { 0x20AA, "NIS" }, { 0x20B1, "P" }, { 0x20BF, "BTC" }, { 0x2190, "\x1b" },
            { 0x1F4A1, "!" }, { 0x1F4CC, "*" }, { 0x1F4E7, "@" }, { 0x1F4DE, "T" }, { 0x260E, "T" },
            { 0x1F50D, "?" }, { 0x1F512, "#" }, { 0x2709, "@" },
            { 0x40F, "Dz" }, { 0x45F, "dz" }, { 0x405, "S" }, { 0x455, "s" }, { 0x408, "J" }, { 0x458, "j" },
            { 0, "" } };
        int i;
        for (i = 0; near[i].u; i++)
            if (near[i].u == u) {
                int k = 0;
                while (near[i].t[k] && k < 3) { out[k] = near[i].t[k]; k++; }
                return k;
            }
    }
    if ((u >= 0x1F300 && u <= 0x1FAFF) || (u >= 0x2600 && u <= 0x27BF)) { out[0] = '*'; return 1; }   /* emoji */
    if (u >= 0xF0080 && u <= 0xF00FF) { out[0] = (char)(u - 0xF0000); return 1; }   /* (code page 866 as it is) */
    if (u == 0x456 || u == 0x457) { out[0] = 'i'; return 1; }   /* Ukrainian */
    if (u == 0x454) { out[0] = (char)0xA5; return 1; }
    if (u == 0x491) { out[0] = (char)0xA3; return 1; }
    out[0] = '?';
    return 1;
}

/* ============================================================
 * the page's charset: UTF-8, or one of the older one-byte ones
 * ============================================================ */
enum { CS_UTF8, CS_1251, CS_KOI8, CS_1252, CS_8859_5, CS_866 };
static int cs_mode;
static const unsigned short cs_1251[64] = {
    0x402, 0x403, 0x201A, 0x453, 0x201E, 0x2026, 0x2020, 0x2021, 0x20AC, 0x2030, 0x409, 0x2039, 0x40A, 0x40C, 0x40B, 0x40F,
    0x452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, '?', 0x2122, 0x459, 0x203A, 0x45A, 0x45C, 0x45B, 0x45F,
    0xA0, 0x40E, 0x45E, 0x408, 0xA4, 0x490, 0xA6, 0xA7, 0x401, 0xA9, 0x404, 0xAB, 0xAC, 0xAD, 0xAE, 0x407,
    0xB0, 0xB1, 0x406, 0x456, 0x491, 0xB5, 0xB6, 0xB7, 0x451, 0x2116, 0x454, 0xBB, 0x458, 0x405, 0x455, 0x457 };
static const unsigned short cs_koi8[128] = {
    0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524, 0x252C, 0x2534, 0x253C, 0x2580, 0x2584, 0x2588, 0x258C, 0x2590,
    0x2591, 0x2592, 0x2593, 0x2320, 0x25A0, 0x2219, 0x221A, 0x2248, 0x2264, 0x2265, 0xA0, 0x2321, 0xB0, 0xB2, 0xB7, 0xF7,
    0x2550, 0x2551, 0x2552, 0x451, 0x2553, 0x2554, 0x2555, 0x2556, 0x2557, 0x2558, 0x2559, 0x255A, 0x255B, 0x255C, 0x255D, 0x255E,
    0x255F, 0x2560, 0x2561, 0x401, 0x2562, 0x2563, 0x2564, 0x2565, 0x2566, 0x2567, 0x2568, 0x2569, 0x256A, 0x256B, 0x256C, 0xA9,
    0x44E, 0x430, 0x431, 0x446, 0x434, 0x435, 0x444, 0x433, 0x445, 0x438, 0x439, 0x43A, 0x43B, 0x43C, 0x43D, 0x43E,
    0x43F, 0x44F, 0x440, 0x441, 0x442, 0x443, 0x436, 0x432, 0x44C, 0x44B, 0x437, 0x448, 0x44D, 0x449, 0x447, 0x44A,
    0x42E, 0x410, 0x411, 0x426, 0x414, 0x415, 0x424, 0x413, 0x425, 0x418, 0x419, 0x41A, 0x41B, 0x41C, 0x41D, 0x41E,
    0x41F, 0x42F, 0x420, 0x421, 0x422, 0x423, 0x416, 0x412, 0x42C, 0x42B, 0x417, 0x428, 0x42D, 0x429, 0x427, 0x42A };
static const unsigned short cs_1252[32] = {
    0x20AC, '?', 0x201A, 0x192, 0x201E, 0x2026, 0x2020, 0x2021, 0x2C6, 0x2030, 0x160, 0x2039, 0x152, '?', 0x17D, '?',
    '?', 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x2DC, 0x2122, 0x161, 0x203A, 0x153, '?', 0x17E, 0x178 };

/* the character at b[*p] (of n), in the page's charset; *p past it */
static unsigned dec(const char *b, int n, int *p)
{
    unsigned c = (unsigned char)b[*p];
    (*p)++;
    if (c < 0x80) return c;
    if (cs_mode == CS_UTF8) {
        int k = 0;
        unsigned u;
        if ((c & 0xE0) == 0xC0) { u = c & 0x1F; k = 1; }
        else if ((c & 0xF0) == 0xE0) { u = c & 0x0F; k = 2; }
        else if ((c & 0xF8) == 0xF0) { u = c & 0x07; k = 3; }
        else return '?';
        while (k-- && *p < n && (b[*p] & 0xC0) == 0x80) u = u << 6 | (b[(*p)++] & 0x3F);
        return u;
    }
    switch (cs_mode) {
    case CS_1251: return c >= 0xC0 ? 0x410 + c - 0xC0 : cs_1251[c - 0x80];
    case CS_KOI8: return cs_koi8[c - 0x80];
    case CS_1252: return c >= 0xA0 ? c : cs_1252[c - 0x80];
    case CS_8859_5: return c >= 0xA1 && c != 0xAD ? 0x360 + c : c;
    case CS_866: return 0xF0000 + c;
    }
    return c;
}
static unsigned next_char(int *p) { return dec(src, srclen, p); }
static void put_char(unsigned u);
/* an attribute's words (alt="", value="") -> put_char's */
static void put_attr_text(const char *t)
{
    int n = strlen(t), p = 0;
    while (p < n) put_char(dec(t, n, &p));
}
/* a charset's name -> CS_*, -1 not known */
static int cs_named(const char *n)
{
    static const struct { const char *n; int m; } names[] = {
        { "utf-8", CS_UTF8 }, { "utf8", CS_UTF8 }, { "us-ascii", CS_UTF8 }, { "ascii", CS_UTF8 },
        { "windows-1251", CS_1251 }, { "cp1251", CS_1251 }, { "x-cp1251", CS_1251 }, { "win-1251", CS_1251 },
        { "koi8-r", CS_KOI8 }, { "koi8-u", CS_KOI8 }, { "koi8", CS_KOI8 },
        { "iso-8859-1", CS_1252 }, { "windows-1252", CS_1252 }, { "latin1", CS_1252 }, { "iso-8859-15", CS_1252 },
        { "cp1252", CS_1252 }, { "iso-8859-5", CS_8859_5 }, { "ibm866", CS_866 }, { "cp866", CS_866 }, { 0, 0 } };
    int i;
    for (i = 0; names[i].n; i++) if (starts_ci(n, names[i].n) && !n[strlen(names[i].n)]) return names[i].m;
    return -1;
}
static const char *cs_name(int m)
{
    static const char *n[] = { "UTF-8", "windows-1251", "KOI8-R", "windows-1252", "ISO-8859-5", "CP866" };
    return m >= 0 && m <= CS_866 ? n[m] : "?";
}
/* not said: the bytes looked at - UTF-8 if they're good UTF-8; if not,
 * letters in runs are Cyrillic (lower case mostly: E0-FF in 1251,
 * C0-DF in KOI8-R), alone among Latin ones a Western accent */
static int cs_guess(const char *b, int n)
{
    int i, bad = 0, good = 0, high = 0, runs = 0, upper = 0, lower = 0;
    for (i = 0; i < n;) {
        unsigned c = (unsigned char)b[i];
        int k = 0;
        if (c < 0x80) { i++; continue; }
        if ((c & 0xE0) == 0xC0) k = 1; else if ((c & 0xF0) == 0xE0) k = 2; else if ((c & 0xF8) == 0xF0) k = 3;
        if (k && i + k < n) {
            int j;
            for (j = 1; j <= k; j++) if (((unsigned char)b[i + j] & 0xC0) != 0x80) break;
            if (j > k) { good++; i += k + 1; continue; }
        }
        bad++;
        i++;
    }
    if (!bad || good > bad * 8) return CS_UTF8;
    for (i = 0; i < n; i++) {
        unsigned c = (unsigned char)b[i];
        if (c < 0xC0) continue;
        high++;
        if (i + 1 < n && (unsigned char)b[i + 1] >= 0xC0) runs++;
        if (c >= 0xE0) lower++; else upper++;
    }
    if (runs * 3 < high) return CS_1252;
    return lower >= upper ? CS_1251 : CS_KOI8;
}

static const struct { const char *name; unsigned u; } entities[] = {
    { "amp", '&' }, { "lt", '<' }, { "gt", '>' }, { "quot", '"' }, { "apos", '\'' },
    { "nbsp", 0xA0 }, { "copy", 0xA9 }, { "mdash", 0x2014 }, { "ndash", 0x2013 },
    { "laquo", 0xAB }, { "raquo", 0xBB }, { "hellip", 0x2026 }, { "bull", 0x2022 },
    { "middot", 0xB7 }, { "deg", 0xB0 }, { "rarr", 0x2192 }, { "larr", 0x2190 },
    { "lsquo", 0x2018 }, { "rsquo", 0x2019 }, { "ldquo", 0x201C }, { "rdquo", 0x201D },
    { "aacute", 0xE1 }, { "eacute", 0xE9 }, { "iacute", 0xED }, { "oacute", 0xF3 },
    { "uacute", 0xFA }, { "ntilde", 0xF1 }, { "Ntilde", 0xD1 }, { "iquest", 0xBF },
    { "iexcl", 0xA1 }, { "uuml", 0xFC }, { "shy", 0xAD }, { "euro", 0x20AC }, { "pound", 0xA3 },
    { "cent", 0xA2 }, { "yen", 0xA5 }, { "sect", 0xA7 }, { "para", 0xB6 }, { "reg", 0xAE }, { "trade", 0x2122 },
    { "times", 0xD7 }, { "divide", 0xF7 }, { "plusmn", 0xB1 }, { "frac12", 0xBD }, { "frac14", 0xBC },
    { "frac34", 0xBE }, { "sup1", 0xB9 }, { "sup2", 0xB2 }, { "sup3", 0xB3 }, { "micro", 0xB5 },
    { "ensp", 0x2002 }, { "emsp", 0x2003 }, { "thinsp", 0x2009 }, { "zwnj", 0x200C }, { "zwj", 0x200D },
    { "lrm", 0x200E }, { "rlm", 0x200F }, { "sbquo", 0x201A }, { "bdquo", 0x201E }, { "dagger", 0x2020 },
    { "Dagger", 0x2021 }, { "permil", 0x2030 }, { "lsaquo", 0x2039 }, { "rsaquo", 0x203A }, { "prime", 0x2032 },
    { "Prime", 0x2033 }, { "minus", 0x2212 }, { "le", 0x2264 }, { "ge", 0x2265 }, { "ne", 0x2260 },
    { "asymp", 0x2248 }, { "infin", 0x221E }, { "uarr", 0x2191 }, { "darr", 0x2193 }, { "harr", 0x2194 },
    { "rArr", 0x21D2 }, { "lArr", 0x21D0 }, { "hearts", 0x2665 }, { "spades", 0x2660 }, { "clubs", 0x2663 },
    { "diams", 0x2666 }, { "radic", 0x221A }, { "check", 0x2713 }, { "star", 0x2606 }, { "starf", 0x2605 },
    { "numero", 0x2116 }, { "Aacute", 0xC1 }, { "Eacute", 0xC9 }, { "Iacute", 0xCD }, { "Oacute", 0xD3 },
    { "Uacute", 0xDA }, { "Uuml", 0xDC }, { "ccedil", 0xE7 }, { "Ccedil", 0xC7 }, { "szlig", 0xDF },
    { "ouml", 0xF6 }, { "auml", 0xE4 }, { "Ouml", 0xD6 }, { "Auml", 0xC4 }, { "eacute", 0xE9 }, { "egrave", 0xE8 },
    { "agrave", 0xE0 }, { "acirc", 0xE2 }, { "ecirc", 0xEA }, { "ocirc", 0xF4 }, { "icirc", 0xEE }, { "ucirc", 0xFB },
    { "atilde", 0xE3 }, { "otilde", 0xF5 }, { "aring", 0xE5 }, { "oslash", 0xF8 }, { "aelig", 0xE6 },
    { "iuml", 0xEF }, { "euml", 0xEB }, { "yuml", 0xFF }, { "igrave", 0xEC }, { "ograve", 0xF2 }, { "ugrave", 0xF9 },
    { "ordm", 0xBA }, { "ordf", 0xAA }, { "curren", 0xA4 }, { "brvbar", 0xA6 }, { "not", 0xAC },
    { "macr", 0xAF }, { "acute", 0xB4 }, { "cedil", 0xB8 }, { "quest", '?' }, { "excl", '!' }, { "num", '#' },
    { "dollar", '$' }, { "percnt", '%' }, { "lpar", '(' }, { "rpar", ')' }, { "ast", '*' }, { "plus", '+' },
    { "comma", ',' }, { "period", '.' }, { "sol", '/' }, { "colon", ':' }, { "semi", ';' }, { "equals", '=' },
    { "lsqb", '[' }, { "rsqb", ']' }, { "lowbar", '_' }, { "lcub", '{' }, { "rcub", '}' }, { "verbar", '|' },
    { "Tab", 9 }, { "NewLine", 10 }, { 0, 0 }
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
    while (q < srclen && n < 10 && ((src[q] >= 'a' && src[q] <= 'z') || (src[q] >= 'A' && src[q] <= 'Z') || (n && src[q] >= '0' && src[q] <= '9')))
        name[n++] = src[q++];
    name[n] = 0;
    for (i = 0; entities[i].name; i++)
        if (!strcmp(entities[i].name, name)) {
            if (q < srclen && src[q] == ';') q++;
            *p = q;
            return entities[i].u;
        }
    if (n > 3 && q < srclen && src[q] == ';' &&                   /* &Xacute; &xcaron; ...: the letter */
        (!strcmp(name + 1, "acute") || !strcmp(name + 1, "grave") || !strcmp(name + 1, "circ") ||
         !strcmp(name + 1, "uml") || !strcmp(name + 1, "tilde") || !strcmp(name + 1, "cedil") ||
         !strcmp(name + 1, "ring") || !strcmp(name + 1, "caron") || !strcmp(name + 1, "slash") ||
         !strcmp(name + 1, "ogon") || !strcmp(name + 1, "macr") || !strcmp(name + 1, "breve") || !strcmp(name + 1, "dot"))) {
        *p = q + 1;
        return (unsigned char)name[0];
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
static int base_left;                    /* where lines start: the page's left, or a table cell's */
static unsigned color_stack[8];
static int ncolor;
static char word[256];
static int wlen;

static unsigned base_text;
static unsigned cur_color(void)
{
    int dark = ((((page_bg >> 16) & 255) * 299 + ((page_bg >> 8) & 255) * 587 + (page_bg & 255) * 114) / 1000) < 110;
    if (cur_link >= 0) return dark ? RGB(138, 180, 248) : C_LINK;
    if (ncolor) return color_stack[ncolor - 1];
    if (head && !dark && base_text == C_TEXT) return C_HEAD;
    return base_text;
}

static int cur_style(void)
{
    return (bold || head ? ST_BOLD : 0) | (ital ? ST_ITAL : 0) | (under || cur_link >= 0 ? ST_UNDER : 0);
}

static struct item *new_item(int kind)
{
    struct item *it;
    if (!grow(&items, &items_cap, nitems + 1, sizeof *items, ITEMS_MAX)) return 0;
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
    y += lh + (reader ? 7 : 3);
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
    int cw = 8 * scale, w = n * cw, spaced = 0;
    if (pending_space && x > line_left) {
        if (x + cw + w <= RIGHT) { x += cw; spaced = 1; }
        else end_line(0);
    }
    pending_space = 0;
    if (x + w > RIGHT && x > line_left) end_line(0);
    if (nitems > line_start && x + w <= RIGHT) {         /* the same as the last, just after it: one piece */
        struct item *l = &items[nitems - 1];
        int gap = x - (l->x + l->w);
        if (l->kind == IT_TEXT && l->text + l->len == npool && l->scale == scale && l->style == cur_style() &&
            l->color == cur_color() && l->link == cur_link && (gap == 0 || (gap == cw && spaced)) &&
            POOL_ROOM(n + 1)) {
            if (gap) { pool[npool++] = ' '; l->len++; l->w += cw; }
            memcpy(pool + npool, t, n);
            npool += n;
            l->len += n;
            l->w += w;
            x += w;
            return;
        }
    }
    while (n > 0) {
        int fit = (RIGHT - x) / cw, k;
        if (fit < 1) fit = 1;
        k = n < fit ? n : fit;
        if (!POOL_ROOM(k) || !(it = new_item(IT_TEXT))) return;
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
    if (!grow(&link_off, &links_cap, nlinks + 1, sizeof *link_off, LINKS_MAX) ||
        !grow(&lpool, &lpool_cap, nlpool + n, 1, LPOOL_MAX)) return -1;
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

/* ============================================================
 * downloads: a file (not a page) from the web, straight into
 * /DOWNLOADS as it comes (so as big as a file can be, 4MB), the status
 * line showing how much has come; Esc stops it
 * ============================================================ */
#define DL_LIST 12
#define HDR_MAX 8192
static struct { char name[16]; int size, ok; } dls[DL_LIST];
static int ndls, show_dls, show_info;
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
    static const char *pages[] = { "HTM", "HTML", "MD", "PHP", "ASP", "ASPX", "JSP", "CGI", "SHTML", "TXT", "XHTML",
                                   "JSON", "XML", "RSS", "ATOM", "CSS", "JS", "CSV", "LOG", "C", "H", "PY", "ASM", "INI",
                                   "JPG", "JPEG", "PNG", "GIF", "BMP", "SVG", "PL", "RB", "GO", "RS", "JAVA", "SH", 0 };
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
    if (fwrite(dl_fd, d, n) != n) { dl_stop = 3; return; }   /* (the disk's full) */
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
        tls_headers = "User-Agent: Mozilla/5.0 (compatible; LexOS-Web/2.0)\r\nAccept: */*\r\nAccept-Encoding: identity\r\n";
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
        append(req, "\r\nUser-Agent: Mozilla/5.0 (compatible; LexOS-Web/2.0)\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n", sizeof req);
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
    if (r == 0 && !dl_stop && !dl_chunked && dl_total > 0 && dl_written < dl_total) dl_stop = 4;
    if (r != 0 || dl_stop) {
        copy(status, dl_stop == 1 ? "Download stopped." : dl_stop == 3 ? "The disk is full." :
                     dl_stop == 4 ? "The download was cut off: " :
                     dl_stop == 2 ? "Can't write it to /DOWNLOADS." : "The download didn't work.", sizeof status);
        if (dl_stop == 4) {                                       /* (how much of it came) */
            num_kb(status, dl_written, sizeof status);
            append(status, " of ", sizeof status);
            num_kb(status, dl_total, sizeof status);
        }
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

/* ============================================================
 * fetching: http:// and https:// (or this disk), the answer a piece at
 * a time - its headers read (the type, the charset, gzip, chunked,
 * where it moved), its body undone (chunks joined, gzip unpacked) and
 * sent on: a page's HTML made smaller on the way in (scripts, SVG,
 * comments, attributes nobody here reads and runs of spaces left out -
 * so a page of megabytes fits), its <style> read as it passes; a style
 * sheet into css.h; a picture into a buffer
 * ============================================================ */
enum { T_PAGE, T_CSS, T_BUF };
enum { PK_HTML, PK_TEXT, PK_IMAGE, PK_FILE, PK_MD, PK_SNIFF };
static struct {                                          /* what came (Ctrl+I) */
    int code, raw, body, kept, trunc, gz, kind, cs_how, css_files, hidden, imgs, imgs_bad, total;
    char ctype[48], cenc[24], cs_hdr[24], cs_meta[24];
} pi;
static int tg;                                           /* where the body goes */
static unsigned char *tbuf;
static int tcap, tlen, tbuf_auto;
#define TBUF_MAX (16 * 1024 * 1024)                      /* a picture: this big at most */
static char ph[HDR_MAX + 1];                             /* the headers */
static int ph_n, ph_body, ph_chunked, ph_cstate, ph_cleft, ph_stop;
static char ph_moved[URL_MAX];
static unsigned char *zbuf;                              /* gzip'd: gathered, then unpacked */
static int zn, zcap;
static char css_links[4][URL_MAX];
static int ncss_links;
static char base_url[URL_MAX];                           /* <base href>, or the page's address */
static unsigned progress_at;

static int strstr_ci(const char *s, const char *w)
{
    for (; *s; s++) if (starts_ci(s, w)) return 1;
    return 0;
}
static const char *strstr_at(const char *s, const char *w)
{
    for (; *s; s++) if (starts_ci(s, w)) return s;
    return 0;
}
/* ---- the HTML made smaller as it comes (T_PAGE, PK_HTML) ---- */
enum { SS_TEXT, SS_TAG, SS_SKIP, SS_CSS, SS_COMMENT, SS_GT };
static int st_state, st_pre, st_space, st_q, st_last, st_match, st_tn;
static char st_tag[3072], st_end[12];
static void st_out(int c) { if (srclen + 1 < src_cap || SRC_ROOM(srclen + 1)) src[srclen++] = c; else pi.trunc = 1; }
static void st_outs(const char *t) { while (*t) st_out(*t++); }
/* what a page that builds itself with JavaScript still says without
 * it: its data's <script>s (JSON, window.__STATE__ = {...},
 * self.__next_f.push(...)) kept here, its <meta> description, where
 * <meta http-equiv=refresh> sends it; and how much text it showed */
#define JX_MAX (768 * 1024)
static char *jx, st_pre_js[96], meta_desc[600], refresh_to[URL_MAX];
static int jxn, st_json, st_pjn, st_textn, refresh_wait;
static void st_reset(void)
{
    st_state = SS_TEXT; st_pre = st_q = st_last = st_match = st_tn = 0; st_space = 1;
    jxn = st_json = st_textn = 0; meta_desc[0] = refresh_to[0] = 0;
}
static void jx_put(int c)
{
    if (!jx) jx = malloc(JX_MAX);
    if (jx && jxn < JX_MAX - 1) jx[jxn++] = c;
}
static const char *st_keep[] = { "href", "src", "data-src", "alt", "title", "class", "id", "style", "hidden",
    "color", "bgcolor", "value", "type", "rel", "name", "content", "charset", "http-equiv", "open", "role",
    "aria-hidden", "start", "media", "colspan", "border", "width", "align", "action", "method", "checked",
    "selected", "placeholder", "rows", "cols", "maxlength", "size", "enctype", "disabled", "multiple", 0 };
/* a whole tag in st_tag: kept (its attributes that matter), or not */
static void st_tag_done(void)
{
    char name[16], an[24];
    int q = 1, n = 0, closing = 0, i, self = 0;
    static char av[URL_MAX + 160];
    if (st_tag[q] == '/') { closing = 1; q++; }
    while (q < st_tn && n < 15 && ((st_tag[q] >= 'a' && st_tag[q] <= 'z') || (st_tag[q] >= 'A' && st_tag[q] <= 'Z') ||
                                   (st_tag[q] >= '0' && st_tag[q] <= '9') || st_tag[q] == '-')) name[n++] = lower(st_tag[q++]);
    name[n] = 0;
    if (!n) return;                                      /* <!DOCTYPE>, <?xml?> */
    if (st_tn > 2 && st_tag[st_tn - 2] == '/') self = 1;
    if (!closing) {
        if (!strcmp(name, "iframe")) {                   /* a page in the page: a link to it */
            const char *a = strstr_at(st_tag, " src=");
            if (a) {
                char h[URL_MAX];
                int k = 0;
                a += 5;
                if (*a == '"' || *a == '\'') a++;
                while (*a && *a != '"' && *a != '\'' && *a != '>' && !is_space(*a) && k < URL_MAX - 1) h[k++] = *a++;
                h[k] = 0;
                if (k && !starts_ci(h, "about:") && !starts_ci(h, "javascript:") && !starts_ci(h, "data:")) {
                    const char *w = h, *e;
                    st_outs("<div class=\"lx-frame\"><a href=\""); st_outs(h); st_outs("\">[Embedded: ");
                    if (starts_ci(w, "https://")) w += 8; else if (starts_ci(w, "http://")) w += 7; else if (starts_ci(w, "//")) w += 2;
                    for (e = w; *e && *e != '/' && *e != '?'; e++) st_out(*e);
                    if (e == w) st_outs("this site");
                    st_outs(" - open]</a></div>");
                }
            }
        }
        if (!strcmp(name, "script")) {                   /* its data? */
            const char *t = strstr_at(st_tag, "type=");
            st_json = (t && strstr_at(t, "json") && strstr_at(t, "json") - t < 30) ||
                      strstr_ci(st_tag, "__NEXT_DATA__") || strstr_ci(st_tag, "__NUXT") ? 1 : 2;
            if (t && st_json == 2 && !strstr_ci(t, "javascript") && !strstr_ci(t, "module") && t[5] != '\0' &&
                strstr_at(t, "text/") == t + 6) st_json = 0;       /* (templates and such) */
            st_pjn = 0;
        } else st_json = 0;
        if (!strcmp(name, "script") || !strcmp(name, "template") || !strcmp(name, "iframe") || !strcmp(name, "math") ||
            (!strcmp(name, "svg") && !self)) {
            copy(st_end, name, sizeof st_end);
            st_state = SS_SKIP; st_match = 0;
            return;
        }
        if (!strcmp(name, "style")) { css_begin(); copy(st_end, "style", sizeof st_end); st_state = SS_CSS; st_match = 0; return; }
    }
    if (!strcmp(name, "pre") || !strcmp(name, "textarea") || !strcmp(name, "listing") || !strcmp(name, "xmp")) {
        if (closing) { if (st_pre) st_pre--; } else st_pre++;
    }
    if (closing) {
        if (!strcmp(name, "source") || !strcmp(name, "picture") || !strcmp(name, "object")) return;
        st_outs("</"); st_outs(name); st_out('>');
        st_space = 0;
        return;
    }
    {                                                    /* its attributes */
        static char kept[1600];
        int nk = 0, is_meta = !strcmp(name, "meta"), is_link = !strcmp(name, "link"), is_base = !strcmp(name, "base");
        char rel[32] = "", href[URL_MAX] = "", media[32] = "", mname[32] = "";
        static char mcont[URL_MAX];
        mcont[0] = 0;
        kept[0] = 0;
        while (q < st_tn) {
            int k = 0, v = 0, has_v = 0;
            while (q < st_tn && (is_space(st_tag[q]) || st_tag[q] == '/')) q++;
            if (q >= st_tn || st_tag[q] == '>') break;
            while (q < st_tn && !is_space(st_tag[q]) && st_tag[q] != '=' && st_tag[q] != '>') { if (k < 23) an[k++] = lower(st_tag[q]); q++; }
            an[k] = 0;
            while (q < st_tn && is_space(st_tag[q])) q++;
            if (st_tag[q] == '=') {
                has_v = 1;
                q++;
                while (q < st_tn && is_space(st_tag[q])) q++;
                if (st_tag[q] == '"' || st_tag[q] == '\'') {
                    char quote = st_tag[q++];
                    while (q < st_tn && st_tag[q] != quote) { if (v < (int)sizeof av - 1) av[v++] = st_tag[q]; q++; }
                    q++;
                } else
                    while (q < st_tn && !is_space(st_tag[q]) && st_tag[q] != '>') { if (v < (int)sizeof av - 1) av[v++] = st_tag[q]; q++; }
            }
            av[v] = 0;
            if (!k) continue;
            if (is_meta) {                               /* <meta charset>, http-equiv's */
                const char *c = 0;
                if (!strcmp(an, "charset")) c = av;
                else if (!strcmp(an, "content")) { const char *t = av; while (*t && !starts_ci(t, "charset=")) t++; if (*t) c = t + 8; }
                if (c && !pi.cs_meta[0]) { int j = 0; while (c[j] && c[j] != ';' && c[j] != ' ' && c[j] != '"' && j < 23) { pi.cs_meta[j] = lower(c[j]); j++; } pi.cs_meta[j] = 0; }
                if (!strcmp(an, "content")) copy(mcont, av, URL_MAX);
                else if (!strcmp(an, "name") || !strcmp(an, "property") || !strcmp(an, "http-equiv")) copy(mname, av, sizeof mname);
                continue;
            }
            if (is_link || is_base) {
                if (!strcmp(an, "rel")) copy(rel, av, sizeof rel);
                else if (!strcmp(an, "href")) copy(href, av, sizeof href);
                else if (!strcmp(an, "media")) copy(media, av, sizeof media);
                continue;
            }
            for (i = 0; st_keep[i]; i++) if (!strcmp(st_keep[i], an)) break;
            if (!st_keep[i]) continue;
            if (starts_ci(av, "data:") || starts_ci(av, "javascript:")) continue;
            if (v > URL_MAX - 1) av[URL_MAX - 1] = 0;
            if (nk + k + (int)strlen(av) + 5 >= (int)sizeof kept) continue;
            kept[nk++] = ' ';
            memcpy(kept + nk, an, k); nk += k;
            if (has_v) {
                const char *t = av;
                kept[nk++] = '='; kept[nk++] = '"';
                while (*t && nk < (int)sizeof kept - 3) { if (*t != '"') kept[nk++] = *t; t++; }
                kept[nk++] = '"';
            }
            kept[nk] = 0;
        }
        if (is_meta && mcont[0]) {
            if ((!strcmp(mname, "description") || !strcmp(mname, "og:description") || !strcmp(mname, "twitter:description")) && !meta_desc[0])
                copy(meta_desc, mcont, sizeof meta_desc);
            else if (starts_ci(mname, "refresh") && !refresh_to[0]) {      /* "5; url=/there" */
                const char *t = mcont;
                refresh_wait = atoi(t);
                while (*t && !starts_ci(t, "url=")) t++;
                if (*t) {
                    t += 4;
                    if (*t == '\'' || *t == '"') t++;
                    copy(refresh_to, t, URL_MAX);
                    { int j = strlen(refresh_to); while (j && (refresh_to[j - 1] == '\'' || refresh_to[j - 1] == '"' || is_space(refresh_to[j - 1]))) refresh_to[--j] = 0; }
                }
            }
        }
        if (is_base) { if (href[0]) resolve(url, href, base_url); return; }
        if (is_link) {
            const char *r = rel;
            while (*r && !starts_ci(r, "stylesheet")) r++;
            if (*r && href[0] && !starts_ci(media, "print") && ncss_links < 4) copy(css_links[ncss_links++], href, URL_MAX);
            return;
        }
        if (is_meta || !strcmp(name, "source") || !strcmp(name, "track") || !strcmp(name, "param") || !strcmp(name, "wbr") ||
            !strcmp(name, "picture") || !strcmp(name, "object") || !strcmp(name, "col") || !strcmp(name, "colgroup")) return;
        st_out('<'); st_outs(name); st_outs(kept); st_out('>');
        st_space = 0;
    }
}
static void st_feed(int c)
{
    switch (st_state) {
    case SS_TEXT:
        if (c == '<') { st_tn = 0; st_tag[st_tn++] = '<'; st_q = 0; st_last = '<'; st_state = SS_TAG; return; }
        if (!st_pre && is_space(c)) { if (!st_space) { st_out(' '); st_space = 1; } return; }
        st_space = 0;
        st_textn++;
        st_out(c);
        return;
    case SS_TAG:
        if (st_tn == 1 && !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '/' || c == '!' || c == '?')) {
            st_out('<');                                 /* ("<" as text) */
            st_state = SS_TEXT;
            st_space = 0;
            st_feed(c);
            return;
        }
        if (st_tn < (int)sizeof st_tag - 2) st_tag[st_tn++] = c;
        if (st_tn == 4 && !memcmp(st_tag, "<!--", 4)) { st_state = SS_COMMENT; st_match = 0; return; }
        if (st_q) { if (c == st_q) st_q = 0; return; }
        if ((c == '"' || c == '\'') && st_last == '=') { st_q = c; return; }
        if (!is_space(c)) st_last = c;
        if (c == '>') {
            st_tag[st_tn] = 0;
            st_state = SS_TEXT;
            st_tag_done();
        }
        return;
    case SS_COMMENT:                                     /* up to --> */
        if (c == '-') st_match++;
        else if (c == '>' && st_match >= 2) st_state = SS_TEXT;
        else st_match = 0;
        return;
    case SS_SKIP:
    case SS_CSS: {                                       /* up to </name */
        int n = strlen(st_end);
        if (st_state == SS_CSS) css_feed(c);
        else if (st_json == 1) jx_put(c);
        else if (st_json == 2) {                         /* a script: data, by its start? */
            if (st_pjn < (int)sizeof st_pre_js - 1) {
                st_pre_js[st_pjn++] = c;
                st_pre_js[st_pjn] = 0;
                if (st_pjn == (int)sizeof st_pre_js - 1 || c == '{' || c == '(') {
                    const char *t = st_pre_js;
                    while (is_space(*t)) t++;
                    if ((starts_ci(t, "window.__") || starts_ci(t, "self.__next_f") || starts_ci(t, "window[\"__") ||
                         starts_ci(t, "var __") || starts_ci(t, "__")) && (c == '{' || c == '(')) {
                        st_json = 1;
                        jx_put('\n');
                        jx_put(c);
                    } else if (c == '{' || c == '(' || st_pjn == (int)sizeof st_pre_js - 1) st_json = 0;
                }
            }
        }
        if (st_match == 0) { if (c == '<') st_match = 1; return; }
        if (st_match == 1) { st_match = c == '/' ? 2 : c == '<' ? 1 : 0; return; }
        if (lower(c) == st_end[st_match - 2]) {
            if (++st_match - 2 == n) {
                if (st_state == SS_CSS) css_begin();     /* ("</style" isn't CSS) */
                st_state = SS_GT;
            }
            return;
        }
        st_match = c == '<' ? 1 : 0;
        return;
    }
    case SS_GT:
        if (c == '>') { st_state = SS_TEXT; st_space = 0; }
        return;
    }
}

/* ---- the body's bytes, undone, to where they go ---- */
static void pg_kind_sniff(const unsigned char *d, int n)
{
    int i = 0;
    if (n >= 3 && d[0] == 0xEF && d[1] == 0xBB && d[2] == 0xBF) i = 3;
    while (i < n && is_space(d[i])) i++;
    if (n - i >= 4 && (!memcmp(d + i, "\x89PNG", 4) || (d[i] == 0xFF && d[i + 1] == 0xD8) || !memcmp(d + i, "GIF8", 4) ||
                       (d[i] == 'B' && d[i + 1] == 'M'))) pi.kind = PK_IMAGE;
    else if (i < n && d[i] == '<') pi.kind = PK_HTML;
    else {
        int k, zeros = 0;
        for (k = i; k < n && k < i + 512; k++) if (!d[k]) zeros++;
        pi.kind = zeros || (n - i >= 4 && (!memcmp(d + i, "%PDF", 4) || !memcmp(d + i, "PK\3\4", 4))) ? PK_FILE : PK_TEXT;
    }
}
static int pg_emit(const unsigned char *d, int n)
{
    int i;
    pi.body += n;
    if (tg == T_CSS) { for (i = 0; i < n; i++) css_feed(d[i]); return 0; }
    if (tg == T_BUF) {
        int k;
        if (tbuf_auto && tlen + n > tcap && tcap < TBUF_MAX) {           /* (more room) */
            int want = tcap ? tcap * 2 : 64 * 1024;
            unsigned char *b;
            while (want < tlen + n) want *= 2;
            if (want > TBUF_MAX) want = TBUF_MAX;
            b = malloc(want);
            if (b) { if (tbuf) { memcpy(b, tbuf, tlen); free(tbuf); } tbuf = b; tcap = want; }
        }
        k = n < tcap - tlen ? n : tcap - tlen;
        if (k > 0) { memcpy(tbuf + tlen, d, k); tlen += k; }
        return tlen >= tcap && (!tbuf_auto || tcap >= TBUF_MAX);
    }
    if (pi.kind == PK_SNIFF) pg_kind_sniff(d, n);
    if (pi.kind == PK_IMAGE || pi.kind == PK_FILE) return 1;           /* (not read here) */
    if (pi.kind == PK_HTML && !view_source) { for (i = 0; i < n; i++) st_feed(d[i]); }
    else for (i = 0; i < n; i++) st_out(d[i]);
    return pi.trunc;
}
static int pg_put1(int c) { unsigned char b = c; return pg_emit(&b, 1); }
static int pg_body_bytes(const unsigned char *d, int n)
{
    pi.raw += n;
    if (pi.gz == 3) return 1;
    if (pi.gz) {                                         /* gathered, unpacked at the end - */
        if (zn + n > zcap && !grow(&zbuf, &zcap, zn + n, 1, ZBUF_MAX)) { pi.trunc = 1; return 1; }
        memcpy(zbuf + zn, d, n);
        zn += n;
        return 0;
    }
    return pg_emit(d, n);
}
/* the status line, now and then: how much has come */
static void pg_progress(void)
{
    if (tg == T_BUF || millis() - progress_at < 250) return;
    progress_at = millis();
    copy(status, tg == T_CSS ? "Loading its styles... " : "Loading... ", sizeof status);
    num_kb(status, pi.raw, sizeof status);
    draw_status();
    gfx_blit_rect(frame, 0, H - STATUS, W, STATUS);
}
/* the headers read: what it is, how it's sent */
static void ph_headers(void)
{
    int j;
    ph[ph_n] = 0;
    pi.code = ph_n > 12 && !memcmp(ph, "HTTP/", 5) ? atoi(ph + 9) : 0;
    for (j = 0; j < ph_n; j++) {
        const char *h = ph + j + 1;
        if (ph[j] != '\n') continue;
        if (starts_ci(h, "transfer-encoding:") && starts_ci(h + 18 + (h[18] == ' '), "chunked")) ph_chunked = 1;
        if (starts_ci(h, "set-cookie:")) ck_set(h + 11);
        if (starts_ci(h, "content-length:")) pi.total = atoi(h + 15);
        if (starts_ci(h, "location:")) {
            const char *l = h + 9;
            int k = 0;
            while (*l == ' ') l++;
            while (*l && *l != '\r' && *l != '\n' && k < URL_MAX - 1) ph_moved[k++] = *l++;
            ph_moved[k] = 0;
        }
        if (starts_ci(h, "content-encoding:")) {
            const char *l = h + 17;
            int k = 0;
            while (*l == ' ') l++;
            while (*l && *l != '\r' && *l != '\n' && k < 23) pi.cenc[k++] = lower(*l++);
            pi.cenc[k] = 0;
            if (starts_ci(pi.cenc, "gzip") || starts_ci(pi.cenc, "x-gzip")) pi.gz = 1;
            else if (starts_ci(pi.cenc, "deflate")) pi.gz = 2;
            else if (!starts_ci(pi.cenc, "identity")) pi.gz = 3;            /* br, zstd: can't - asked again */
        }
        if (starts_ci(h, "content-type:") && tg != T_BUF) {
            const char *l = h + 13, *c;
            int k = 0;
            while (*l == ' ') l++;
            for (c = l; *c && *c != '\r' && *c != '\n' && *c != ';' && k < 47; c++) pi.ctype[k++] = lower(*c);
            pi.ctype[k] = 0;
            for (; *c && *c != '\r' && *c != '\n'; c++)
                if (starts_ci(c, "charset=")) {
                    const char *v = c + 8;
                    k = 0;
                    if (*v == '"') v++;
                    while (*v && *v != '\r' && *v != '\n' && *v != ';' && *v != '"' && *v != ' ' && k < 23) pi.cs_hdr[k++] = lower(*v++);
                    pi.cs_hdr[k] = 0;
                    break;
                }
        }
    }
    ck_save();
    if (tg == T_BUF && tbuf_auto && pi.total > 0 && pi.total <= TBUF_MAX && !pi.gz && pi.total > tcap) {
        unsigned char *b = malloc(pi.total);             /* (its size said: that much) */
        if (b) { if (tbuf) { memcpy(b, tbuf, tlen); free(tbuf); } tbuf = b; tcap = pi.total; }
    }
    if (tg == T_PAGE && !view_source) {                  /* the kind of thing */
        const char *t = pi.ctype;
        if (!*t || !strcmp(t, "application/octet-stream") || !strcmp(t, "binary/octet-stream")) pi.kind = PK_SNIFF;
        else if (starts_ci(t, "text/html") || starts_ci(t, "application/xhtml")) pi.kind = PK_HTML;
        else if (starts_ci(t, "image/svg")) pi.kind = PK_FILE;
        else if (starts_ci(t, "image/")) pi.kind = PK_IMAGE;
        else if (starts_ci(t, "text/markdown")) pi.kind = PK_MD;
        else if (starts_ci(t, "text/") || starts_ci(t, "application/json") || starts_ci(t, "application/javascript") ||
                 starts_ci(t, "application/xml") || starts_ci(t, "application/rss") || starts_ci(t, "application/atom") ||
                 starts_ci(t, "application/ld+json") || starts_ci(t, "application/x-javascript")) pi.kind = PK_TEXT;
        else pi.kind = PK_FILE;
    }
}
/* chunked: the pieces joined */
static int ph_chunks(const unsigned char *d, int n)
{
    int i = 0;
    while (i < n) {
        if (ph_cstate == 0) {                            /* its size, in hex */
            int c = d[i++];
            if (hexval(c) >= 0) ph_cleft = ph_cleft * 16 + hexval(c);
            else if (c == ';') ph_cstate = 4;            /* (an extension: to the line's end) */
            else if (c == '\n') ph_cstate = ph_cleft ? 1 : 3;
        } else if (ph_cstate == 4) { if (d[i++] == '\n') ph_cstate = ph_cleft ? 1 : 3; }
        else if (ph_cstate == 1) {
            int k = n - i < ph_cleft ? n - i : ph_cleft;
            if (pg_body_bytes(d + i, k)) return 1;
            i += k;
            ph_cleft -= k;
            if (!ph_cleft) ph_cstate = 2;
        } else if (ph_cstate == 2) { if (d[i++] == '\n') { ph_cstate = 0; ph_cleft = 0; } }
        else return 0;                                   /* the end */
    }
    return 0;
}
/* the answer as it comes (tls_sink, or tcp_recv's pieces) */
static int ph_feed(const unsigned char *d, int n)
{
    int i = 0;
    while (!ph_body && i < n) {
        if (ph_n < HDR_MAX) ph[ph_n++] = d[i];
        i++;
        if (ph_n >= 4 && !memcmp(ph + ph_n - 4, "\r\n\r\n", 4)) {
            ph_body = 1;
            ph_headers();
            if (pi.code >= 300 && pi.code < 400 && ph_moved[0]) return 1;       /* moved: there instead */
            if (pi.code == 100) { ph_n = 0; ph_body = 0; }                     /* (go on) */
        }
    }
    if (i < n) { if (ph_chunked ? ph_chunks(d + i, n - i) : pg_body_bytes(d + i, n - i)) ph_stop = 1; }
    pg_progress();
    return ph_stop;
}
static int ph_sink(const unsigned char *d, int n) { return ph_feed(d, n); }

/* ---- cookies: what servers ask to be told again (Set-Cookie), kept
 * in /TMP/WEB/COOKIES (a line each: domain, path, name, value, flags)
 * and sent back to the same sites (Cookie:) - logins, settings, a
 * form's session ---- */
#define CK_MAX 300
struct cookie { char dom[64], path[64], name[64], val[384]; char host_only, secure; };
static struct cookie *ck;
static int nck, ck_loaded, ck_dirty;
static char cur_host[URL_MAX];
static int cur_https;
static int ck_room(void) { if (!ck) ck = malloc(CK_MAX * sizeof *ck); return ck != 0; }
static void ck_load(void)
{
    int fd, n, i, f, st;
    char *b;
    if (ck_loaded || !ck_room()) return;
    ck_loaded = 1;
    if ((fd = open("/TMP/WEB/COOKIES", O_READ)) < 0) return;
    n = fsize(fd);
    if (n <= 0 || n > 512 * 1024 || !(b = malloc(n + 1))) { close(fd); return; }
    n = read(fd, b, n);
    close(fd);
    b[n > 0 ? n : 0] = 0;
    for (i = 0, st = 0; i <= n && nck < CK_MAX; i++)
        if (i == n || b[i] == '\n') {
            char *fld[5], *l = b + st;
            int k = 0;
            b[i] = 0;
            fld[k++] = l;
            for (f = st; f < i && k < 5; f++) if (b[f] == '\t') { b[f] = 0; fld[k++] = b + f + 1; }
            if (k == 5) {
                struct cookie *c = &ck[nck++];
                copy(c->dom, fld[0], sizeof c->dom); copy(c->path, fld[1], sizeof c->path);
                copy(c->name, fld[2], sizeof c->name); copy(c->val, fld[3], sizeof c->val);
                c->host_only = fld[4][0] == 'h' || fld[4][1] == 'h'; c->secure = fld[4][0] == 's';
            }
            st = i + 1;
        }
    free(b);
}
static void ck_save(void)
{
    int fd, i;
    if (!ck_dirty || !ck) return;
    ck_dirty = 0;
    mkdir("/TMP/WEB");
    if ((fd = open("/TMP/WEB/COOKIES", O_WRITE)) < 0) return;
    for (i = 0; i < nck; i++) {
        char l[600];
        copy(l, ck[i].dom, sizeof l); append(l, "\t", sizeof l); append(l, ck[i].path, sizeof l); append(l, "\t", sizeof l);
        append(l, ck[i].name, sizeof l); append(l, "\t", sizeof l); append(l, ck[i].val, sizeof l); append(l, "\t", sizeof l);
        append(l, ck[i].secure ? "s" : "-", sizeof l); append(l, ck[i].host_only ? "h\n" : "-\n", sizeof l);
        fwrite(fd, l, strlen(l));
    }
    close(fd);
}
/* host's a dom's, or one of its sub-domains? */
static int ck_dom_ok(const char *host, const char *dom, int host_only)
{
    int hl = strlen(host), dl = strlen(dom), i;
    if (hl < dl) return 0;
    for (i = 0; i < dl; i++) if (lower(host[hl - dl + i]) != lower(dom[i])) return 0;
    if (hl == dl) return 1;
    return !host_only && host[hl - dl - 1] == '.';
}
/* a Set-Cookie: header's text, from cur_host */
static void ck_set(const char *h)
{
    char name[64], val[384], dom[64], path[64];
    int k = 0, i, del = 0, host_only = 1, secure = 0;
    if (!ck_room()) return;
    ck_load();
    while (*h == ' ') h++;
    while (*h && *h != '=' && *h != ';' && *h != '\r' && *h != '\n' && k < 63) name[k++] = *h++;
    name[k] = 0;
    while (k && name[k - 1] == ' ') name[--k] = 0;
    if (!k || *h != '=') return;
    h++;
    k = 0;
    while (*h && *h != ';' && *h != '\r' && *h != '\n' && k < 383) val[k++] = *h++;
    val[k] = 0;
    copy(dom, cur_host, sizeof dom);
    copy(path, "/", sizeof path);
    while (*h == ';') {                                  /* its attributes */
        char an[16], av[64];
        int a = 0, v = 0;
        h++;
        while (*h == ' ') h++;
        while (*h && *h != '=' && *h != ';' && *h != '\r' && *h != '\n' && a < 15) an[a++] = lower(*h++);
        an[a] = 0;
        if (*h == '=') { h++; while (*h && *h != ';' && *h != '\r' && *h != '\n' && v < 63) av[v++] = *h++; }
        av[v] = 0;
        while (*h && *h != ';' && *h != '\r' && *h != '\n') h++;
        if (!strcmp(an, "domain") && av[0]) {
            const char *d = av[0] == '.' ? av + 1 : av;
            if (ck_dom_ok(cur_host, d, 0)) { copy(dom, d, sizeof dom); host_only = 0; }
        } else if (!strcmp(an, "path") && av[0] == '/') copy(path, av, sizeof path);
        else if (!strcmp(an, "max-age") && atoi(av) <= 0 && (av[0] == '0' || av[0] == '-')) del = 1;
        else if (!strcmp(an, "expires")) {               /* (a year gone by: gone) */
            int j;
            for (j = 0; av[j]; j++)
                if (av[j] >= '1' && av[j] <= '2' && av[j + 1] >= '0' && av[j + 3] >= '0' && av[j + 3] <= '9' && av[j + 4] < '0') {
                    int y = atoi(av + j);
                    if (y > 1900 && y < 2026) del = 1;
                    break;
                }
        } else if (!strcmp(an, "secure")) secure = 1;
    }
    for (i = 0; i < nck; i++)
        if (!strcmp(ck[i].name, name) && !strcmp(ck[i].dom, dom) && !strcmp(ck[i].path, path)) break;
    if (del) {
        if (i < nck) { ck[i] = ck[--nck]; ck_dirty = 1; }
        return;
    }
    if (i == nck) {
        if (nck >= CK_MAX) { memmove(ck, ck + 1, (CK_MAX - 1) * sizeof *ck); i = CK_MAX - 1; }
        else nck++;
    }
    copy(ck[i].name, name, sizeof ck[i].name); copy(ck[i].val, val, sizeof ck[i].val);
    copy(ck[i].dom, dom, sizeof ck[i].dom); copy(ck[i].path, path, sizeof ck[i].path);
    ck[i].host_only = host_only; ck[i].secure = secure;
    ck_dirty = 1;
}
/* "Cookie: a=b; c=d\r\n" for host and path (none: nothing) */
static void ck_header(const char *host, const char *path, int https, char *out, int max)
{
    int i, any = 0;
    out[0] = 0;
    ck_load();
    if (!ck) return;
    for (i = 0; i < nck; i++) {
        struct cookie *c = &ck[i];
        if (c->secure && !https) continue;
        if (!ck_dom_ok(host, c->dom, c->host_only)) continue;
        if (!starts_ci(path, c->path)) continue;
        if ((int)(strlen(out) + strlen(c->name) + strlen(c->val) + 8) >= max) break;
        append(out, any ? "; " : "Cookie: ", max);
        append(out, c->name, max); append(out, "=", max); append(out, c->val, max);
        any = 1;
    }
    if (any) append(out, "\r\n", max);
}
/* the request: GET (or a form's POST), the headers, the cookies */
static int build_req(char *req, int max, const char *host, const char *path, const char *hdrs)
{
    static char cks[8192];
    int n;
    copy(req, post_now ? "POST " : "GET ", max);
    append(req, path, max);
    append(req, " HTTP/1.1\r\nHost: ", max);
    append(req, host, max);
    append(req, "\r\n", max);
    append(req, hdrs, max);
    ck_header(host, path, cur_https, cks, sizeof cks);
    append(req, cks, max);
    if (post_now) {
        char t[16];
        int k = 0, v = post_len;
        append(req, "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: ", max);
        do { t[k++] = '0' + v % 10; v /= 10; } while (v);
        while (k) { char o[2] = { t[--k], 0 }; append(req, o, max); }
        append(req, "\r\n", max);
    }
    append(req, "Connection: close\r\n\r\n", max);
    n = strlen(req);
    if (post_now && n + post_len < max) { memcpy(req + n, post_body, post_len); n += post_len; }
    return n;
}

/* one try at u: 0 had it, 1 moved (ph_moved), -1 no connection, -4 TLS */
static int want_identity;                                /* (asked not to pack it) */
static int net_try(const char *u)
{
    char host[URL_MAX], path[URL_MAX];
    const char *p = u + (is_https(u) ? 8 : 7);
    int port = is_https(u) ? 443 : 80, n = 0;
    static const char *hdrs_page = "User-Agent: Mozilla/5.0 (compatible; LexOS-Web/2.0)\r\n"
                                   "Accept: text/html,application/xhtml+xml,*/*;q=0.8\r\n"
                                   "Accept-Language: ru,en;q=0.8,es;q=0.6\r\nAccept-Encoding: gzip, deflate\r\n";
    static const char *hdrs_plain = "User-Agent: Mozilla/5.0 (compatible; LexOS-Web/2.0)\r\nAccept: */*\r\nAccept-Encoding: identity\r\n";
    static const char *hdrs_page_plain = "User-Agent: Mozilla/5.0 (compatible; LexOS-Web/2.0)\r\n"
                                         "Accept: text/html,application/xhtml+xml,*/*;q=0.8\r\n"
                                         "Accept-Language: ru,en;q=0.8,es;q=0.6\r\nAccept-Encoding: identity\r\n";
    const char *hdrs = tg != T_PAGE ? hdrs_plain : want_identity ? hdrs_page_plain : hdrs_page;
    ph_n = ph_body = ph_chunked = ph_cstate = ph_cleft = ph_stop = 0;
    ph_moved[0] = 0;
    while (*p && *p != '/' && *p != ':' && *p != '?' && n < URL_MAX - 1) host[n++] = *p++;
    host[n] = 0;
    if (*p == ':') { port = atoi(p + 1); while (*p && *p != '/' && *p != '?') p++; }
    if (*p == '?') { copy(path, "/", URL_MAX); append(path, p, URL_MAX); }
    else copy(path, *p ? p : "/", URL_MAX);
    {                                                    /* (no #fragment, no spaces) */
        int i;
        for (i = 0; path[i]; i++) if (path[i] == '#') { path[i] = 0; break; }
        for (i = 0; path[i]; i++) if (path[i] == ' ') path[i] = '+';
    }
    copy(cur_host, host, URL_MAX);
    cur_https = is_https(u);
    if (is_https(u)) {
        static char none[4], req[32768];
        tls_req_len = build_req(req, sizeof req, host, path, hdrs);
        tls_req = req;
        tls_sink = ph_sink;
        n = tls_get(host, port, path, none, 0);
        tls_sink = 0;
        tls_req = 0;
        if (n < 0 && !ph_body && strcmp(tls_error, "Stopped.")) return -4;
    } else {
        static char req[32768];
        static unsigned char piece[4096];
        int rl;
        if (tcp_open(host, port) < 0) return -1;
        rl = build_req(req, sizeof req, host, path, hdrs);
        tcp_send(req, rl);
        for (;;) {
            int got = tcp_recv(piece, sizeof piece, 15000);
            if (got <= 0) break;
            if (ph_feed(piece, got)) break;
        }
        tcp_close();
    }
    if (!ph_body) return -1;
    if (pi.code >= 300 && pi.code < 400 && ph_moved[0]) return 1;
    return 0;
}
static int zb_put(int c) { return pg_put1(c); }
/* where (http, https, or this disk) -> tg's (T_PAGE: src; T_CSS; T_BUF:
 * tbuf, tcap): 0, or <0 (-1 no answer, -2 nothing there, -4 TLS);
 * final: the address it ended at (moved) */
static int net_get(const char *where, char *final)
{
    char u[URL_MAX];
    int tries, r = -1;
    zn = 0;
    copy(u, where, URL_MAX);
    if (!is_http(u)) {                                   /* this disk */
        static unsigned char piece[4096];
        int fd = open(u, O_READ), got;
        if (fd < 0) return -1;
        pi.code = 200;
        while ((got = read(fd, piece, sizeof piece)) > 0) {
            pi.raw += got;
            if (pg_emit(piece, got)) break;
        }
        close(fd);
        if (final) copy(final, u, URL_MAX);
        return 0;
    }
    want_identity = 0;
    for (tries = 0; tries < 6; tries++) {
        int kind = pi.kind;
        pi.raw = pi.body = pi.gz = 0; pi.cenc[0] = 0; pi.ctype[0] = 0; pi.cs_hdr[0] = 0; pi.total = 0;
        if (tg == T_PAGE) { srclen = 0; pi.trunc = 0; st_reset(); pi.kind = kind; }
        if (tg == T_BUF) tlen = 0;
        zn = 0;
        post_now = tg == T_PAGE && post_body && !tries;  /* (a form's POST: the first try; moved: GET) */
        r = net_try(u);
        post_now = 0;
        if (r >= 0 && pi.gz == 3 && !want_identity) { want_identity = 1; continue; }   /* (packed in a way we can't undo) */
        if (r != 1) break;
        {
            char moved[URL_MAX];
            resolve(u, ph_moved, moved);
            copy(u, moved, URL_MAX);
        }
        if (!is_http(u)) { r = -2; break; }
    }
    if (r == 1) r = -2;
    if (r >= 0 && pi.gz == 3) r = -5;
    if (r >= 0 && zn) {                                  /* gzip'd: unpacked now */
        int z = pi.gz == 1 ? gunzip(zbuf, zn, zb_put) : zinflate(zbuf, zn, zb_put);
        if (z < 0 && !pi.body) r = -2;
    }
    free(zbuf); zbuf = 0; zn = zcap = 0;
    if (final) copy(final, u, URL_MAX);
    return r;
}

/* a picture: where -> *out (malloc'd, as big as it is), its length
 * (or <0) */
static int load_auto(const char *where, unsigned char **out)
{
    int save_tg = tg, n;
    static char pi_copy[sizeof pi];
    memcpy(pi_copy, &pi, sizeof pi);                     /* (the page's, kept) */
    tg = T_BUF; tbuf = 0; tcap = 0; tlen = 0; tbuf_auto = 1;
    n = net_get(where, 0);
    tg = save_tg; tbuf_auto = 0;
    memcpy(&pi, pi_copy, sizeof pi);
    *out = tbuf;
    tbuf = 0;
    if (n < 0) { free(*out); *out = 0; return n; }
    return tlen;
}

/* ---- the cache: pictures and style sheets from the web, kept in
 * /TMP/WEB (TMP's an ordinary folder on the disk: they stay there
 * across restarts). 64 files, W00..W3F, one per address's hash - a new
 * one with the same hash takes its place, so it never grows past 64
 * (each 512KB at most); each begins with "LXC1", the address's length
 * and the address, then what came. F5 reads past it. ---- */
#define CACHE_SLOTS 64
#define CACHE_MAX (512 * 1024)
static int cache_reload, cache_hits, cache_dir_made;
static void cache_name(const char *u, char *out)
{
    unsigned h = 2166136261u;
    int i, v;
    for (i = 0; u[i]; i++) h = (h ^ (unsigned char)u[i]) * 16777619u;
    v = (h ^ h >> 16) % CACHE_SLOTS;
    copy(out, "/TMP/WEB/W00", 16);
    out[10] = "0123456789ABCDEF"[v >> 4];
    out[11] = "0123456789ABCDEF"[v & 15];
}
static int cache_get(const char *u, unsigned char **out)
{
    char nm[16], had[URL_MAX];
    unsigned char hd[6];
    int fd, l = strlen(u), n;
    cache_name(u, nm);
    if ((fd = open(nm, O_READ)) < 0) return -1;
    n = fsize(fd) - 6 - l;
    if (read(fd, hd, 6) != 6 || memcmp(hd, "LXC1", 4) || (hd[4] | hd[5] << 8) != l || l >= URL_MAX ||
        read(fd, had, l) != l || memcmp(had, u, l) || n <= 0 || !(*out = malloc(n))) { close(fd); return -1; }
    if (read(fd, *out, n) != n) { close(fd); free(*out); *out = 0; return -1; }
    close(fd);
    cache_hits++;
    return n;
}
static void cache_put(const char *u, const unsigned char *d, int n)
{
    char nm[16];
    unsigned char hd[6];
    int fd, l = strlen(u);
    if (n <= 0 || n > CACHE_MAX || l >= URL_MAX) return;
    if (!cache_dir_made) { mkdir("/TMP/WEB"); cache_dir_made = 1; }
    cache_name(u, nm);
    if ((fd = open(nm, O_WRITE)) < 0) return;
    memcpy(hd, "LXC1", 4); hd[4] = l & 255; hd[5] = l >> 8;
    fwrite(fd, hd, 6);
    fwrite(fd, u, l);
    fwrite(fd, d, n);
    close(fd);
}
/* where -> *out, from the cache if it's there (the web's only), else
 * read - and then kept */
static int load_cached(const char *where, unsigned char **out)
{
    int n;
    if (is_http(where) && !cache_reload && (n = cache_get(where, out)) > 0) return n;
    n = load_auto(where, out);
    if (n > 0 && *out && is_http(where)) cache_put(where, *out, n);
    return n;
}

#define IMG_MAX_PAGE 64                   /* pictures read for a page, at most */
/* a picture's 0xRRGGBB pixels -> 16-bit ones (5-6-5) in the same block,
 * the block's other half given back to malloc */
static void to16(unsigned *pix, int n)
{
    unsigned short *o = (unsigned short *)pix;
    int i;
    for (i = 0; i < n; i++) {
        unsigned c = pix[i];
        o[i] = (c >> 8 & 0xF800) | (c >> 5 & 0x07E0) | (c >> 3 & 0x001F);
    }
    realloc(pix, n * 2);                          /* (smaller: in place) */
}
static int img_count;
static int is_svg(const char *u)
{
    int l = 0;
    while (u[l] && u[l] != '?' && u[l] != '#') l++;
    return l > 4 && starts_ci(u + l - 4, ".svg");
}
static void emit_image(const char *srcattr, const char *alt)
{
    char where[URL_MAX];
    int n, w = 0, h = 0, f = 1, cap, maxw = RIGHT - line_left;
    unsigned *pix = 0;
    unsigned char *buf = 0;
    if (maxw < 48) maxw = 48;
    resolve(base_url[0] ? base_url : url, srcattr, where);
    if (img_count < IMG_MAX_PAGE && !is_svg(where)) {
        img_count++;
        (void)cap;
        {
            copy(status, "Loading pictures... ", sizeof status);
            {
                char t[8];
                int k = 0, v = img_count;
                do { t[k++] = '0' + v % 10; v /= 10; } while (v);
                while (k) { char c[2] = { t[--k], 0 }; append(status, c, sizeof status); }
            }
            draw_status();
            gfx_blit_rect(frame, 0, H - STATUS, W, STATUS);
            n = load_cached(where, &buf);
            if (n > 8 && buf) {
                if (buf[0] == 137 && buf[1] == 'P') pix = load_png(buf, n, &w, &h);
                else if (buf[0] == 0xFF && buf[1] == 0xD8) pix = jpeg_load(buf, n, maxw, 1600, &w, &h);
                else if (!memcmp(buf, "GIF8", 4)) pix = gif_load(buf, n, maxw, 1600, page_bg, &w, &h);
                else pix = load_bmp(buf, n, &w, &h);
            }
            free(buf);
        }
    }
    if (!pix) {                           /* not shown: its words instead */
        int save = ital;
        const char *a = alt && *alt ? alt : "[picture]";
        pi.imgs_bad++;
        if (alt && !*alt) return;                        /* (alt="": just decoration) */
        ital = 1;
        flush_word();
        pending_space = 1;
        put_attr_text(a);
        flush_word();
        ital = save;
        return;
    }
    if (w <= 2 && h <= 2) { free(pix); return; }         /* (a counter's pixel) */
    pi.imgs++;
    while (w / f > maxw) f++;             /* too wide: smaller */
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
    to16(pix, w * h);                                    /* (kept in half the room) */
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
#define ATTRS 12
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

static int is_void(const char *n)
{
    static const char *v[] = { "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
                               "source", "track", "wbr", "keygen", 0 };
    int i;
    for (i = 0; v[i]; i++) if (!strcmp(v[i], n)) return 1;
    return 0;
}
/* the rest of an element that isn't shown: up to its own end (the same
 * tags inside it counted) */
static void skip_element(int *p, const char *name)
{
    int n = strlen(name), depth = 1;
    while (*p < srclen) {
        if (src[*p] == '<') {
            int q = *p + 1, closing = 0;
            if (src[q] == '/') { closing = 1; q++; }
            if (starts_ci(src + q, name)) {
                char c = src[q + n];
                if (c == '>' || c == ' ' || c == '/' || is_space(c)) {
                    depth += closing ? -1 : 1;
                    if (!depth) {
                        while (*p < srclen && src[*p] != '>') (*p)++;
                        (*p)++;
                        return;
                    }
                }
            }
        }
        (*p)++;
    }
}
static void skip_to_end_of(int *p, const char *name) { skip_element(p, name); }
static int luma(unsigned c) { return (((c >> 16) & 255) * 299 + ((c >> 8) & 255) * 587 + (c & 255) * 114) / 1000; }
/* can it be read on the page's background? */
static int readable(unsigned c)
{
    int d = luma(c) - luma(page_bg);
    return d > 70 || d < -70;
}
/* the reader: what isn't the article's (by its tag, its class, its id) */
static int reader_skip(const char *name)
{
    static const char *tags[] = { "nav", "footer", "aside", "form", "button", "select", "dialog", "iframe", "menu", 0 };
    static const char *words[] = { "nav", "menu", "footer", "sidebar", "comment", "share", "social", "related",
        "banner", "cookie", "subscribe", "promo", "breadcrumb", "advert", "sponsor", "popup", "modal", "newsletter",
        "widget", "toolbar", "rating", "recommend", "signup", "login", 0 };
    const char *cl = attr("class"), *id = attr("id");
    int i;
    for (i = 0; tags[i]; i++) if (!strcmp(tags[i], name)) return 1;
    if (strcmp(name, "div") && strcmp(name, "section") && strcmp(name, "ul") && strcmp(name, "ol") && strcmp(name, "span"))
        return 0;
    for (i = 0; words[i]; i++)
        if ((cl && strstr_ci(cl, words[i])) || (id && strstr_ci(id, words[i]))) return 1;
    return 0;
}
/* an element's own looks (its rules, its style="", hidden...) -> 1 if
 * it isn't shown at all */
static int el_style(const char *name, struct css_style *st)
{
    static const char *hid[] = { "sr-only", "visually-hidden", "visuallyhidden", "screen-reader-text", "screenreader",
        "hidden", "d-none", "is-hidden", "u-hidden", "hide", "invisible", "skip-link", "a11y-hidden", "sr-text", 0 };
    const char *cl = attr("class"), *sty = attr("style"), *ah = attr("aria-hidden");
    int i;
    memset(st, 0, sizeof *st);
    if (attr("hidden")) return 1;
    if (ah && !strcmp(ah, "true")) return 1;
    if (!strcmp(name, "dialog") && !attr("open")) return 1;
    if (cl) for (i = 0; hid[i]; i++) if (css_has_class(cl, hid[i])) return 1;
    if (reader && reader_skip(name)) return 1;
    css_match(name, cl, attr("id"), st);
    if (sty) css_inline(sty, st);
    if (st->hide) return 1;
    if ((!strcmp(name, "body") || !strcmp(name, "html")) && !reader) {
        if (st->has_bg) page_bg = st->bg;
        if (st->has_color && readable(st->color)) base_text = st->color;
        if (luma(page_bg) < 110 && !readable(base_text)) base_text = RGB(224, 226, 230);
        st->has_color = 0;
    }
    return 0;
}
/* its looks on while it's open (bold, italic, underlined, centered, a
 * color), off at its end tag */
#define CSSF_MAX 48
static struct { char name[12]; char b, i, u, c, col; } cssf[CSSF_MAX];
static int ncssf;
static int is_block(const char *n)
{
    static const char *b[] = { "p", "div", "section", "article", "header", "footer", "main", "td", "th", "li", "h1", "h2",
        "h3", "h4", "h5", "h6", "table", "blockquote", "figure", "figcaption", "center", "nav", "aside", "dd", "dt", 0 };
    int i;
    for (i = 0; b[i]; i++) if (!strcmp(b[i], n)) return 1;
    return 0;
}
static void css_push(const char *name, struct css_style *st)
{
    int col = st->has_color && readable(st->color) && ncolor < 8;
    int cen = st->center && is_block(name);
    if (!st->bold && !st->ital && !st->under && !cen && !col) return;
    if (ncssf >= CSSF_MAX) return;
    copy(cssf[ncssf].name, name, sizeof cssf[0].name);
    cssf[ncssf].b = st->bold; cssf[ncssf].i = st->ital; cssf[ncssf].u = st->under;
    cssf[ncssf].c = cen; cssf[ncssf].col = col;
    if (cen && strcmp(name, "td") && strcmp(name, "th")) end_line(0);   /* (the line before it stays where it was) */
    bold += st->bold; ital += st->ital; under += st->under; center += cen;
    if (col) color_stack[ncolor++] = st->color;
    ncssf++;
}
static void css_pop(const char *name)
{
    int k;
    for (k = ncssf - 1; k >= 0 && k >= ncssf - 8; k--) if (!strcmp(cssf[k].name, name)) break;
    if (k < 0 || k < ncssf - 8) return;
    while (ncssf > k) {
        ncssf--;
        bold -= cssf[ncssf].b; ital -= cssf[ncssf].i; under -= cssf[ncssf].u; center -= cssf[ncssf].c;
        if (cssf[ncssf].col && ncolor) ncolor--;
        if (bold < 0) bold = 0;
        if (ital < 0) ital = 0;
        if (under < 0) under = 0;
        if (center < 0) center = 0;
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
    if (POOL_ROOM(8) && (it = new_item(IT_TEXT))) {
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

/* ---- forms ----
 * <form>'s fields are things on the page of their own (IT_CTRL): a
 * click on a text field and the keys type into it (Russian too), a
 * check box or a radio button is clicked, a list (<select>) opens
 * under itself, a button - or Enter in a field - sends the form: GET
 * (its fields after the address's "?") or POST (in the request's body),
 * url-encoded, in the page's own charset. What a field held when the
 * page came (hidden ones, tokens) goes back byte for byte. */
#define CTRL_MAX 400
#define FORMS_MAX 64
#define VAL_MAX 2048
enum { CT_TEXT, CT_PASS, CT_AREA, CT_CHECK, CT_RADIO, CT_SELECT, CT_SUBMIT, CT_HIDDEN, CT_BUTTON, CT_IMAGE };
struct ctrl {
    unsigned char kind, checked, edited, rows;
    short form, item, sel, nopt;
    char name[64];
    char *val, *raw;                      /* shown (the font's bytes), the page's own */
    char *opts;                           /* <select>: "text\0value\0" for each */
    char ph[40];                          /* placeholder */
};
struct form { char action[URL_MAX]; char post; };
static struct ctrl ctrls[CTRL_MAX];
static struct form forms[FORMS_MAX];
static int nctrls, nforms, cur_form = -1, focus = -1, sel_open = -1;
static int isalnum_c(int c);

/* a character of the font -> Unicode (to_font's other way) */
static unsigned font_uni(unsigned char c)
{
    if (c < 128) return c;
    if (c >= 0x80 && c <= 0xAF) return 0x410 + c - 0x80;
    if (c >= 0xE0 && c <= 0xEF) return 0x440 + c - 0xE0;
    switch (c) {
    case 0xF0: return 0x401; case 0xF1: return 0x451; case 0xF2: return 0xE1; case 0xF3: return 0xE9;
    case 0xF4: return 0xED; case 0xF5: return 0xF3; case 0xF6: return 0xFA; case 0xF7: return 0xF1;
    case 0xFC: return 0xD1; case 0xFD: return 0xFC; case 0xB5: return 0xBF; case 0xB6: return 0xA1;
    case 0xF8: return 0xB0; case 0xB7: return 0xE7; case 0xB8: return 0xC7;
    }
    return '?';
}
/* Unicode -> bytes in charset cs (out: 4 at most) -> how many */
static int uni_cs(unsigned u, int cs, char *o)
{
    int i;
    if (u < 128) { o[0] = u; return 1; }
    switch (cs) {
    case CS_UTF8:
        if (u < 0x800) { o[0] = 0xC0 | u >> 6; o[1] = 0x80 | (u & 63); return 2; }
        if (u < 0x10000) { o[0] = 0xE0 | u >> 12; o[1] = 0x80 | (u >> 6 & 63); o[2] = 0x80 | (u & 63); return 3; }
        o[0] = 0xF0 | u >> 18; o[1] = 0x80 | (u >> 12 & 63); o[2] = 0x80 | (u >> 6 & 63); o[3] = 0x80 | (u & 63); return 4;
    case CS_1251:
        if (u >= 0x410 && u <= 0x44F) { o[0] = 0xC0 + u - 0x410; return 1; }
        for (i = 0; i < 64; i++) if (cs_1251[i] == u) { o[0] = 0x80 + i; return 1; }
        break;
    case CS_KOI8:
        for (i = 0; i < 128; i++) if (cs_koi8[i] == u) { o[0] = 0x80 + i; return 1; }
        break;
    case CS_1252:
        if (u >= 0xA0 && u < 0x100) { o[0] = u; return 1; }
        for (i = 0; i < 32; i++) if (cs_1252[i] == u) { o[0] = 0x80 + i; return 1; }
        break;
    case CS_8859_5:
        if (u >= 0x401 && u <= 0x45F) { o[0] = u - 0x360; return 1; }
        if (u < 0x100) { o[0] = u; return 1; }
        break;
    case CS_866:
        if (u >= 0xF0000) { o[0] = u - 0xF0000; return 1; }
        { char f[3]; if (to_font(u, f) == 1) { o[0] = f[0]; return 1; } }
        break;
    }
    o[0] = '?';
    return 1;
}
/* an attribute's text, the next character: its entities (&amp; &#39;)
 * undone, the page's charset read */
static unsigned attr_next(const char *t, int n, int *p)
{
    if (t[*p] == '&') {
        int q = *p + 1, k = 0, i;
        char nm[12];
        unsigned u = 0;
        if (t[q] == '#') {
            q++;
            if (lower(t[q]) == 'x') { q++; while (q < n && hexval(t[q]) >= 0) u = u * 16 + hexval(t[q++]); }
            else while (q < n && t[q] >= '0' && t[q] <= '9') u = u * 10 + t[q++] - '0';
            if (t[q] == ';') q++;
            *p = q;
            return u;
        }
        while (q < n && k < 10 && ((t[q] >= 'a' && t[q] <= 'z') || (t[q] >= 'A' && t[q] <= 'Z'))) nm[k++] = t[q++];
        nm[k] = 0;
        if (t[q] == ';')
            for (i = 0; entities[i].name; i++)
                if (!strcmp(entities[i].name, nm)) { *p = q + 1; return entities[i].u; }
        (*p)++;
        return '&';
    }
    return dec(t, n, p);
}
/* text (the page's bytes, entities and all) -> raw (the page's charset,
 * entities undone) and shown (the font's) */
static void ctrl_text(struct ctrl *c, const char *t, int n)
{
    int p = 0, r = 0, v = 0;
    free(c->raw); free(c->val);
    c->raw = malloc(VAL_MAX); c->val = malloc(VAL_MAX);
    if (!c->raw || !c->val) { free(c->raw); free(c->val); c->raw = c->val = 0; return; }
    while (p < n) {
        unsigned u = attr_next(t, n, &p);
        char o[4], f[3];
        int k = uni_cs(u, cs_mode, o), m = to_font(u, f), i;
        if (u == '\r') continue;
        if (r + k < VAL_MAX - 1) for (i = 0; i < k; i++) c->raw[r++] = o[i];
        if (u == '\n' || u == '\t') { f[0] = u == '\n' ? '\n' : ' '; m = 1; }
        if (v + m < VAL_MAX - 1) for (i = 0; i < m; i++) c->val[v++] = f[i];
    }
    c->raw[r] = 0; c->val[v] = 0;
}
static void ctrls_free(void)
{
    int i;
    for (i = 0; i < nctrls; i++) { free(ctrls[i].val); free(ctrls[i].raw); free(ctrls[i].opts); }
    nctrls = nforms = 0;
    cur_form = -1; focus = -1; sel_open = -1;
}
/* a new field, on the line where the words are (as a picture is) */
static struct ctrl *ctrl_add(int kind, int w, int h)
{
    struct ctrl *c;
    struct item *it;
    if (nctrls >= CTRL_MAX) return 0;
    c = &ctrls[nctrls];
    memset(c, 0, sizeof *c);
    c->kind = kind; c->form = cur_form; c->item = -1;
    if (kind != CT_HIDDEN) {
        flush_word();
        if (pending_space && x > line_left) x += 8;
        pending_space = 0;
        if (w > RIGHT - line_left) w = RIGHT - line_left;
        if (x + w > RIGHT && x > line_left) end_line(0);
        if (!(it = new_item(IT_CTRL))) return 0;
        it->x = x; it->w = w; it->h = h; it->text = nctrls;
        c->item = nitems - 1;
        x += w + 4;
        pending_space = 1;
    }
    nctrls++;
    { const char *nm = attr("name"); if (nm) copy(c->name, nm, sizeof c->name); }
    return c;
}
/* the text up to </name> at src+*p (tags left out) -> *p past it */
static int ctrl_inner(int *p, const char *name, int *start, int keep_tags)
{
    int q = *p, l = strlen(name), end;
    *start = q;
    while (q < srclen && !(src[q] == '<' && src[q + 1] == '/' && starts_ci(src + q + 2, name) && !isalnum_c(src[q + 2 + l]))) q++;
    end = q;
    while (q < srclen && src[q] != '>') q++;
    *p = q < srclen ? q + 1 : q;
    (void)keep_tags;
    return end;
}
static int isalnum_c(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'); }
/* <input>, <textarea>, <select>, <button>, <form> -> 1 if handled */
static int form_tag(const char *name, int closing, int *p)
{
    struct ctrl *c;
    const char *a;
    if (!strcmp(name, "form")) {
        if (closing) { cur_form = -1; return 0; }
        if (nforms < FORMS_MAX) {
            a = attr("action");
            copy(forms[nforms].action, a ? a : "", URL_MAX);
            a = attr("method");
            forms[nforms].post = a && starts_ci(a, "post");
            cur_form = nforms++;
        }
        return 0;                                        /* (and a block, as before) */
    }
    if (closing) return 0;
    if (!strcmp(name, "input")) {
        const char *t = attr("type");
        int kind = CT_TEXT, w = 0, h = 22, size;
        if (!t || !*t || starts_ci(t, "text") || starts_ci(t, "search") || starts_ci(t, "email") || starts_ci(t, "url") ||
            starts_ci(t, "tel") || starts_ci(t, "number")) kind = CT_TEXT;
        else if (starts_ci(t, "password")) kind = CT_PASS;
        else if (starts_ci(t, "hidden")) kind = CT_HIDDEN;
        else if (starts_ci(t, "checkbox")) kind = CT_CHECK;
        else if (starts_ci(t, "radio")) kind = CT_RADIO;
        else if (starts_ci(t, "submit")) kind = CT_SUBMIT;
        else if (starts_ci(t, "image")) kind = CT_IMAGE;
        else if (starts_ci(t, "button") || starts_ci(t, "reset")) kind = CT_BUTTON;
        else if (starts_ci(t, "file")) { put_attr_text("[file]"); return 1; }
        else kind = CT_TEXT;
        a = attr("value");
        if (kind == CT_CHECK || kind == CT_RADIO) w = h = 16;
        else if (kind == CT_SUBMIT || kind == CT_BUTTON || kind == CT_IMAGE) {
            const char *l = a && *a ? a : attr("alt") ? attr("alt") : kind == CT_BUTTON ? "..." : "Submit";
            w = strlen(l) * 8 + 20; if (w > 300) w = 300; h = 24;
        } else {
            size = (a = attr("size")) ? atoi(a) : 22;
            if (size < 6) size = 6;
            if (size > 60) size = 60;
            w = size * 8 + 12;
            a = attr("value");
        }
        if (!(c = ctrl_add(kind, w, h))) return 1;
        if (kind == CT_SUBMIT || kind == CT_BUTTON || kind == CT_IMAGE) {
            a = attr("value");
            if (!a || !*a) a = attr("alt");
            if (!a || !*a) a = kind == CT_BUTTON ? "..." : "Submit";
        }
        ctrl_text(c, a ? a : "", a ? strlen(a) : 0);
        if (attr("checked")) c->checked = 1;
        if ((a = attr("placeholder"))) {
            int q = 0, k = 0, n = strlen(a);
            while (q < n && k < (int)sizeof c->ph - 2) { char f[3]; int m = to_font(attr_next(a, n, &q), f), i; for (i = 0; i < m && k < (int)sizeof c->ph - 1; i++) c->ph[k++] = f[i]; }
            c->ph[k] = 0;
        }
        return 1;
    }
    if (!strcmp(name, "textarea")) {
        int rows = (a = attr("rows")) ? atoi(a) : 3, cols = (a = attr("cols")) ? atoi(a) : 40, st, en;
        if (rows < 1) rows = 1;
        if (rows > 12) rows = 12;
        if (cols < 10) cols = 10;
        if (cols > 90) cols = 90;
        c = ctrl_add(CT_AREA, cols * 8 + 12, rows * 16 + 8);
        en = ctrl_inner(p, "textarea", &st, 0);
        if (c) {
            c->rows = rows;
            if (en > st && src[st] == '\n') st++;
            ctrl_text(c, src + st, en - st);
            if ((a = attr("placeholder"))) { int q = 0, k = 0, n = strlen(a); while (q < n && k < 38) { char f[3]; if (to_font(attr_next(a, n, &q), f) == 1) c->ph[k++] = f[0]; } c->ph[k] = 0; }
        }
        css_pop("textarea");
        return 1;
    }
    if (!strcmp(name, "select")) {
        int st, en, q, ol = 0, cap = 4096, wmax = 4, nopt = 0, sel = 0;
        char *opts = malloc(cap);
        char nm[64] = "";
        if ((a = attr("name"))) copy(nm, a, sizeof nm);
        en = ctrl_inner(p, "select", &st, 0);
        if (!opts) return 1;
        for (q = st; q < en; q++) {
            if (src[q] == '<' && starts_ci(src + q + 1, "option") && !isalnum_c(src[q + 7])) {
                char val[URL_MAX];
                int has_val = 0, is_sel = 0, t0 = q, ts, k, tl;
                while (q < en && src[q] != '>') q++;
                {                                        /* its value=, selected */
                    int r;
                    for (r = t0; r < q; r++) {
                        if (starts_ci(src + r, "value=")) {
                            int v = 0; char qc = 0;
                            r += 6;
                            if (src[r] == '"' || src[r] == '\'') qc = src[r++];
                            while (r < q && (qc ? src[r] != qc : !is_space(src[r])) && v < URL_MAX - 1) val[v++] = src[r++];
                            val[v] = 0; has_val = 1;
                        }
                        if (starts_ci(src + r, "selected")) is_sel = 1;
                    }
                }
                ts = ++q;
                while (q < en && src[q] != '<') q++;
                tl = q - ts;
                if (ol + 2 * tl + 2 * URL_MAX + 8 > cap) break;
                {                                        /* its words, as the font has them */
                    int r = 0, m0 = ol;
                    while (r < tl) {
                        char f[3];
                        int m = to_font(attr_next(src + ts, tl, &r), f);
                        for (k = 0; k < m; k++) if (f[k] != '\n' && f[k] != '\r') opts[ol++] = f[k] == '\t' ? ' ' : f[k];
                    }
                    while (ol > m0 && opts[ol - 1] == ' ') ol--;
                    { int s0 = m0; while (s0 < ol && opts[s0] == ' ') s0++; if (s0 > m0) { memmove(opts + m0, opts + s0, ol - s0); ol -= s0 - m0; } }
                    if (ol - m0 > wmax) wmax = ol - m0;
                    opts[ol++] = 0;
                }
                if (has_val) { k = strlen(val); memcpy(opts + ol, val, k + 1); ol += k + 1; }
                else { memcpy(opts + ol, src + ts, tl); ol += tl; opts[ol++] = 0; }
                if (is_sel) sel = nopt;
                nopt++;
                q--;
            }
        }
        if (wmax > 40) wmax = 40;
        c = ctrl_add(CT_SELECT, wmax * 8 + 30, 22);
        if (!c) { free(opts); return 1; }
        copy(c->name, nm, sizeof c->name);
        c->opts = opts; c->nopt = nopt; c->sel = sel;
        css_pop("select");
        return 1;
    }
    if (!strcmp(name, "button")) {
        const char *t = attr("type"), *v = attr("value");
        char nm[64] = "", lab[64];
        int st, en, k = 0, q, n;
        if ((a = attr("name"))) copy(nm, a, sizeof nm);
        en = ctrl_inner(p, "button", &st, 0);
        for (q = st; q < en && k < 60; ) {               /* its words, tags left out */
            if (src[q] == '<') { while (q < en && src[q] != '>') q++; q++; continue; }
            { char f[3]; int m = to_font(src[q] == '&' ? attr_next(src, en, &q) : dec(src, en, &q), f), i;
              for (i = 0; i < m && k < 60; i++) { if (is_space(f[i])) { if (k && lab[k - 1] != ' ') lab[k++] = ' '; } else lab[k++] = f[i]; } }
        }
        while (k && lab[k - 1] == ' ') k--;
        lab[k] = 0;
        if (!k) copy(lab, "Submit", sizeof lab);
        n = strlen(lab);
        c = ctrl_add(t && (starts_ci(t, "button") || starts_ci(t, "reset")) ? CT_BUTTON : CT_SUBMIT, n * 8 + 20 > 300 ? 300 : n * 8 + 20, 24);
        if (c) {
            copy(c->name, nm, sizeof c->name);
            ctrl_text(c, v ? v : "", v ? strlen(v) : 0);
            free(c->val);
            c->val = malloc(n + 1);                      /* (shown: its words; sent: value=) */
            if (c->val) memcpy(c->val, lab, n + 1);
        }
        css_pop("button");
        return 1;
    }
    return 0;
}

/* ---- tables, as grids ----
 * The outermost table's cells are measured first (tb_measure: each
 * column's longest word and longest line), its columns given widths
 * from that - as wide as their text if it all fits, else each its
 * longest word and the rest shared out - and each cell then laid out
 * in its own column, the row as tall as its tallest cell; borders and
 * bgcolor as boxes and rules. Tables inside a cell: as before, their
 * cells one after another in it. */
#define TB_COLS 40
#define TB_PAD 6
static int tb_depth, tb_on, tb_ncol, tb_x, tb_w, tb_col[TB_COLS + 1];
static int tb_cmin[TB_COLS], tb_cmax[TB_COLS];
static int tb_row, tb_row_top, tb_row_bot, tb_ci, tb_cell, tb_cell_th, tb_cell_ctr, tb_border;
static int tb_left0, tb_right0, tb_base0, tb_box[TB_COLS], tb_nbox, tb_edge[TB_COLS], tb_nedge;
static unsigned tb_row_bg, tb_tbl_bg;
static void tb_reset(void) { tb_depth = tb_on = tb_row = tb_cell = 0; }

static int tb_attr_num(const char *t, int n, const char *name)    /* name="12" in a tag's text */
{
    int i, l = strlen(name), v = 0;
    for (i = 0; i + l < n; i++)
        if (starts_ci(t + i, name) && t[i + l] == '=') {
            i += l + 1;
            if (t[i] == '"' || t[i] == '\'') i++;
            while (i < n && t[i] >= '0' && t[i] <= '9') v = v * 10 + t[i++] - '0';
            return v;
        }
    return -1;
}
/* src from p (just past <table>) to its </table>: tb_ncol, tb_cmin, tb_cmax */
static void tb_measure(int p)
{
    int depth = 1, ci = -1, span = 1, len = 0, mline = 0, wd = 0, mword = 0, sp = 0, in_cell = 0;
    tb_ncol = 0;
    memset(tb_cmin, 0, sizeof tb_cmin);
    memset(tb_cmax, 0, sizeof tb_cmax);
#define TB_CELL_END() do { if (in_cell) { if (wd > mword) mword = wd; if (len > mline) mline = len; \
        if (ci >= 0 && ci < TB_COLS && span == 1) { if (mword * 8 > tb_cmin[ci]) tb_cmin[ci] = mword * 8; \
                                                   if (mline * 8 > tb_cmax[ci]) tb_cmax[ci] = mline * 8; } \
        ci += span; if (ci > tb_ncol) tb_ncol = ci; in_cell = 0; } } while (0)
    while (p < srclen) {
        unsigned char c = src[p];
        if (c == '<') {
            char nm[12];
            int q = p + 1, k = 0, cl = 0, t0;
            if (src[q] == '/') { cl = 1; q++; }
            while (q < srclen && k < 11 && ((src[q] >= 'a' && src[q] <= 'z') || (src[q] >= 'A' && src[q] <= 'Z') || (src[q] >= '0' && src[q] <= '9')))
                nm[k++] = lower(src[q++]);
            nm[k] = 0;
            t0 = q;
            while (q < srclen && src[q] != '>') q++;
            p = q + 1;
            if (!k) continue;
            if (!strcmp(nm, "script") || !strcmp(nm, "style")) { if (!cl) skip_to_end(&p, nm); continue; }
            if (!strcmp(nm, "table")) {
                if (!cl) { depth++; continue; }
                if (--depth == 0) break;
                continue;
            }
            if (depth == 1) {
                if (!strcmp(nm, "tr")) { TB_CELL_END(); if (!cl) ci = 0; continue; }
                if (!strcmp(nm, "td") || !strcmp(nm, "th")) {
                    TB_CELL_END();
                    if (cl) continue;
                    if (ci < 0) ci = 0;
                    span = tb_attr_num(src + t0, q - t0, "colspan");
                    if (span < 1) span = 1;
                    in_cell = 1; len = mline = wd = mword = 0; sp = 1;
                    continue;
                }
            }
            if (!in_cell) continue;
            if (!strcmp(nm, "img")) {                    /* a picture: as wide as it says */
                int w = tb_attr_num(src + t0, q - t0, "width");
                w = (w > 0 ? w : 64) / 8 + 1;
                if (wd + w > mword) mword = wd + w;
                len += w;
                continue;
            }
            if (!strcmp(nm, "br") || !strcmp(nm, "p") || !strcmp(nm, "div") || !strcmp(nm, "li") ||
                !strcmp(nm, "tr") || (nm[0] == 'h' && nm[1] >= '1' && nm[1] <= '6')) {
                if (wd > mword) mword = wd;
                if (len > mline) mline = len;
                len = wd = 0; sp = 1;
            }
            continue;
        }
        p++;
        if (!in_cell) continue;
        if (c == '&') { while (p < srclen && src[p] != ';' && src[p] != '<' && !is_space(src[p])) p++; if (src[p] == ';') p++; }
        else if (is_space(c)) { if (wd > mword) mword = wd; wd = 0; if (!sp) { len++; sp = 1; } continue; }
        else if ((c & 0xC0) == 0x80 && cs_mode == 0) continue;     /* (UTF-8: one letter) */
        len++; wd++; sp = 0;
    }
    TB_CELL_END();
#undef TB_CELL_END
    if (tb_ncol > TB_COLS) tb_ncol = TB_COLS;
}
/* the columns' widths and where they start (tb_col), in avail */
static void tb_widths(int avail, int full)
{
    int i, smin = 0, smax = 0, w[TB_COLS], tot = 0;
    for (i = 0; i < tb_ncol; i++) {
        int mx = tb_cmax[i] > avail ? avail : tb_cmax[i];
        tb_cmin[i] += 2 * TB_PAD; mx += 2 * TB_PAD;
        if (tb_cmin[i] > mx) mx = tb_cmin[i];
        tb_cmax[i] = mx;
        smin += tb_cmin[i]; smax += mx;
    }
    for (i = 0; i < tb_ncol; i++) {
        if (smax <= avail) w[i] = full && smax ? tb_cmax[i] + (avail - smax) * tb_cmax[i] / smax : tb_cmax[i];
        else if (smin >= avail) w[i] = smin ? tb_cmin[i] * avail / smin : avail / tb_ncol;
        else w[i] = tb_cmin[i] + (tb_cmax[i] - tb_cmin[i]) * (avail - smin) / (smax - smin);
        if (w[i] < 2 * TB_PAD + 8) w[i] = 2 * TB_PAD + 8;
    }
    tb_col[0] = tb_x;
    for (i = 0; i < tb_ncol; i++) { tot += w[i]; tb_col[i + 1] = tb_x + tot; }
    tb_w = tot;
}
static void tb_rule(int rx, int ry, int rw, int rh)
{
    struct item *it = new_item(IT_RULE);
    if (it) { it->x = rx; it->y = ry; it->w = rw; it->h = rh; it->color = C_RULE; }
    line_start = nitems;
}
static void tb_cell_end(void)
{
    if (!tb_cell) return;
    end_line(0);
    if (y + TB_PAD > tb_row_bot) tb_row_bot = y + TB_PAD;
    if (tb_cell_th) { if (bold) bold--; }
    if (tb_cell_ctr && center) center--;
    tb_cell = 0;
    indent = 0; list_depth = 0;
    base_left = tb_x;
    right_x = tb_x + tb_w;
    set_left(tb_x);
}
static void tb_row_end(void)
{
    int i;
    tb_cell_end();
    if (!tb_row) return;
    for (i = 0; i < tb_nbox; i++) items[tb_box[i]].h = tb_row_bot - tb_row_top;
    if (tb_border) {
        for (i = 0; i < tb_nedge; i++) tb_rule(tb_col[tb_edge[i]], tb_row_top, 1, tb_row_bot - tb_row_top);
        tb_rule(tb_col[tb_ncol] - 1, tb_row_top, 1, tb_row_bot - tb_row_top);   /* (each cell's left edge, the right one) */
        tb_rule(tb_x, tb_row_bot, tb_w, 1);
    }
    y = tb_row_bot + (tb_border ? 1 : 0);
    x = line_left;
    last_gap = 0;
    tb_row = 0;
}
static void tb_row_start(void)
{
    tb_row_end();
    tb_row = 1;
    tb_ci = 0;
    tb_nbox = tb_nedge = 0;
    tb_row_top = tb_row_bot = y;
}
static void tb_cell_start(int th)
{
    int span = 1, l, r;
    const char *a;
    unsigned bg;
    tb_cell_end();
    if (!tb_row) tb_row_start();
    if ((a = attr("colspan"))) span = atoi(a);
    if (span < 1) span = 1;
    if (tb_ci >= tb_ncol) tb_ci = tb_ncol - 1;            /* (more cells than measured: the last) */
    if (tb_ci + span > tb_ncol) span = tb_ncol - tb_ci;
    l = tb_col[tb_ci]; r = tb_col[tb_ci + span];
    if (tb_nedge < TB_COLS) tb_edge[tb_nedge++] = tb_ci;
    tb_ci += span;
    bg = th && !reader ? RGB(236, 240, 247) : tb_row_bg;
    if ((a = attr("bgcolor")) && !reader) bg = parse_color(a, bg);
    if (bg != 0xFFFFFFFFu && tb_nbox < TB_COLS) {
        struct item *it = new_item(IT_BOX);
        if (it) { it->x = l; it->y = tb_row_top; it->w = r - l; it->color = bg; tb_box[tb_nbox++] = nitems - 1; }
    }
    base_left = l + TB_PAD;
    right_x = r - TB_PAD;
    if (right_x < base_left + 8) right_x = base_left + 8;
    line_left = base_left;
    x = base_left;
    y = tb_row_top + TB_PAD;
    line_start = nitems;
    pending_space = 0;
    last_gap = 99;                                       /* (no gap at its top) */
    indent = list_depth = 0;
    tb_cell = 1;
    tb_cell_th = th;
    if (th) bold++;
    a = attr("align");
    tb_cell_ctr = (a && starts_ci(a, "center")) || (th && !a);
    if (tb_cell_ctr) center++;
}
/* <table>, <tr>, <td>/<th> and their ends -> 1 if it's handled here */
static int tb_tag(const char *name, int closing, int *p)
{
    if (!strcmp(name, "table")) {
        if (!closing) {
            const char *a;
            tb_depth++;
            if (tb_depth > 1 || pre) return 0;
            block(10);
            tb_measure(*p);
            if (tb_ncol < 1) return 0;
            tb_on = 1;
            tb_left0 = line_left; tb_right0 = right_x; tb_base0 = base_left;
            tb_x = line_left;
            a = attr("width");
            tb_widths(RIGHT - line_left, a && a[0] && a[strlen(a) - 1] == '%' && atoi(a) >= 90);
            a = attr("border");
            tb_border = a && atoi(a) > 0;
            tb_tbl_bg = 0xFFFFFFFFu;
            if ((a = attr("bgcolor")) && !reader) tb_tbl_bg = parse_color(a, page_bg);
            tb_row_bg = tb_tbl_bg;
            tb_row = tb_cell = 0;
            base_left = tb_x;
            right_x = tb_x + tb_w;
            set_left(tb_x);
            if (tb_border) tb_rule(tb_x, y, tb_w, 1), y++;
            return 1;
        }
        if (tb_depth > 0) tb_depth--;
        if (!tb_on || tb_depth > 0) return 0;
        tb_row_end();
        tb_on = 0;
        right_x = tb_right0; base_left = tb_base0;
        line_left = tb_left0; x = line_left;
        line_start = nitems;
        last_gap = 0;
        block(10);
        return 1;
    }
    if (!tb_on || tb_depth != 1) return 0;
    if (!strcmp(name, "tr")) {
        const char *a;
        if (closing) { tb_row_end(); return 1; }
        tb_row_start();
        tb_row_bg = tb_tbl_bg;
        if ((a = attr("bgcolor")) && !reader) tb_row_bg = parse_color(a, page_bg);
        return 1;
    }
    if (!strcmp(name, "td") || !strcmp(name, "th")) {
        if (closing) tb_cell_end();
        else tb_cell_start(name[1] == 'h');
        return 1;
    }
    return 0;
}

static void tag_rest(char *name, int closing, int *p);
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

    if (!strcmp(name, "script") || !strcmp(name, "style") || !strcmp(name, "svg") || !strcmp(name, "template")) {
        if (!closing) skip_to_end(p, name);
        return;
    }
    if (!strcmp(name, "title")) {
        int t = 0;
        if (closing) return;
        while (*p < srclen && src[*p] != '<') {
            char out[3];
            unsigned u = src[*p] == '&' ? entity(p) : next_char(p);
            int k, m = to_font(is_space(u) ? ' ' : u, out);
            for (k = 0; k < m && t < (int)sizeof title - 1; k++) title[t++] = out[k];
        }
        title[t] = 0;
        skip_to_end(p, "title");
        return;
    }
    flush_word();
    if (!closing) {                                     /* hidden? its looks? (css.h) */
        struct css_style st;
        if (el_style(name, &st)) {
            if (!is_void(name)) skip_element(p, name);
            pi.hidden++;
            return;
        }
        if (!is_void(name)) css_push(name, &st);
    }
    tag_rest(name, closing, p);
    if (closing) css_pop(name);
}

static void tag_rest(char *name, int closing, int *p)
{
    if (tb_tag(name, closing, p)) return;
    if (form_tag(name, closing, p)) return;
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
    if (!strcmp(name, "center")) { block(4); center += closing ? -1 : 1; if (center < 0) center = 0; return; }
    if (!strcmp(name, "blockquote")) {
        block(8);
        indent += closing ? -36 : 36;
        if (indent < 0) indent = 0;
        set_left(base_left + indent + list_depth * 28);
        if (!closing) ital++; else if (ital) ital--;
        return;
    }
    if (!strcmp(name, "ul") || !strcmp(name, "ol") || !strcmp(name, "menu")) {
        block(list_depth ? 2 : 8);
        if (!closing) {
            if (list_depth < 8) { list_ordered[list_depth] = name[0] == 'o'; list_num[list_depth] = 0; }
            list_depth++;
        } else if (list_depth) list_depth--;
        set_left(base_left + indent + list_depth * 28);
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
    if (!strcmp(name, "body")) { if (!closing && attr("bgcolor") && !reader) page_bg = parse_color(attr("bgcolor"), page_bg); return; }
    if (!strcmp(name, "img")) {                                 /* (lazy ones: data-src the real one) */
        const char *s = attr("src"), *ds = attr("data-src");
        if (ds && *ds && (!s || !*s || starts_ci(s, "data:") || strstr_ci(s, "blank") || strstr_ci(s, "placeholder") ||
                          strstr_ci(s, "lazy") || strstr_ci(s, "spacer") || strstr_ci(s, "pixel"))) s = ds;
        if (s && *s) emit_image(s, attr("alt"));
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
    if (!SRC_ROOM(mn)) mn = src_cap - 1;
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

/* the reader: where the article is - <article>, or <main>, or
 * role="main" - its start and its end (the whole page if none) */
static void reader_range(int *from, int *to)
{
    static const char *starts[] = { "<article", "<main", 0 };
    int i, p;
    for (i = 0; starts[i]; i++)
        for (p = 0; p < srclen; p++)
            if (src[p] == '<' && starts_ci(src + p, starts[i]) && (src[p + strlen(starts[i])] == '>' || src[p + strlen(starts[i])] == ' ')) {
                int q = p + 1;
                *from = p;
                skip_to_end_of(&q, starts[i] + 1);
                *to = q;
                return;
            }
    for (p = 0; p < srclen; p++)                         /* role="main" */
        if (starts_ci(src + p, "role=\"main\"")) {
            int q = p, n = 0;
            char name[16];
            while (q > 0 && src[q] != '<') q--;
            *from = q;
            q++;
            while (n < 15 && ((src[q + n] >= 'a' && src[q + n] <= 'z') || (src[q + n] >= 'A' && src[q + n] <= 'Z') || (src[q + n] >= '0' && src[q + n] <= '9'))) { name[n] = lower(src[q + n]); n++; }
            name[n] = 0;
            if (!n) return;
            q = p;
            skip_to_end_of(&q, name);
            *to = q;
            return;
        }
}

/* text as it is (a .TXT, JSON, the page's source): in its charset,
 * lines as they are */
static void layout_plain(void)
{
    int p = 0;
    pre = 1;
    while (p < srclen) put_char(next_char(&p));
    flush_word();
    end_line(0);
}

/* the page's title, before it's laid out (the reader may start past it) */
/* ---- a page that builds itself with JavaScript: its text, from the
 * data it carries (jx: JSON, the state a framework's given, Next.js's
 * pieces) - the strings in it that read like sentences, each once -
 * and its <meta> description; at the page's end, when what it showed
 * without JavaScript was next to nothing ---- */
static unsigned jx_seen[512];
static int jx_nseen, jx_out, jx_strings;
static void jx_scan(const char *d, int n, int depth);
static int jx_key_skip(const char *k)
{
    static const char *no[] = { "className", "class", "style", "src", "srcSet", "srcset", "href", "url", "id", "type",
        "@type", "@context", "@id", "image", "sizes", "path", "as", "rel", "d", "viewBox", "fill", "query", "hash",
        "buildId", "key", "locale", "lang", "contentType", "mimeType", "assetPrefix", "page", "slug", "icon", "logo",
        "sameAs", "datePublished", "dateModified", "uploadDate", "thumbnailUrl", "embedUrl", "contentUrl", "color",
        "variant", "size", "fontFamily", "font", "width", "height", "position", "align", "target", "loading", 0 };
    int i;
    for (i = 0; no[i]; i++) if (!strcmp(no[i], k)) return 1;
    return 0;
}
/* a string (JSON-escaped, n bytes): undone into o (\uXXXX as 1 + three
 * bytes of 6 bits each) -> its length */
static int jx_undo(const char *s, int n, char *o)
{
    int i, k = 0;
    for (i = 0; i < n; i++) {
        unsigned u;
        if (s[i] != '\\' || i + 1 >= n) { o[k++] = s[i]; continue; }
        switch (s[++i]) {
        case 'n': case 'r': case 't': case 'f': case 'b': o[k++] = ' '; continue;
        case 'u':
            if (i + 4 >= n) continue;
            u = hexval(s[i + 1]) << 12 | hexval(s[i + 2]) << 8 | hexval(s[i + 3]) << 4 | hexval(s[i + 4]);
            i += 4;
            if (u >= 0xD800 && u < 0xDC00 && i + 6 < n && s[i + 1] == '\\' && s[i + 2] == 'u') {
                unsigned lo = hexval(s[i + 3]) << 12 | hexval(s[i + 4]) << 8 | hexval(s[i + 5]) << 4 | hexval(s[i + 6]);
                u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
                i += 6;
            }
            if (u < 0x80) { o[k++] = u < 32 ? ' ' : (char)u; continue; }
            o[k++] = 1; o[k++] = 0x80 | (u >> 12 & 63); o[k++] = 0x80 | (u >> 6 & 63); o[k++] = 0x80 | (u & 63);
            continue;
        default: o[k++] = s[i]; continue;
        }
    }
    return k;
}
static void jx_string(const char *s, int n, const char *key, int depth)
{
    char *o, *t;
    int k, i, m = 0, letters = 0, other = 0, spaces = 0, hy = 0, mark = 0;
    unsigned h = 2166136261u;
    if (n < 24 || jx_out > 96 * 1024 || jx_strings >= 600) return;
    if (!(o = malloc(n + 1))) return;
    k = jx_undo(s, n, o);
    o[k] = 0;
    if (depth < 2 && strstr_ci(o, "\"") && (strstr_ci(o, "{") || strstr_ci(o, "["))) { jx_scan(o, k, depth + 1); free(o); return; }
    if (key[0] && jx_key_skip(key)) { free(o); return; }
    t = malloc(k + 1);                                   /* tags out, spaces joined */
    if (!t) { free(o); return; }
    for (i = 0; i < k; i++) {
        int c = (unsigned char)o[i];
        if (c == '<' && i + 1 < k && (isalnum_c(o[i + 1]) || o[i + 1] == '/' || o[i + 1] == '!')) {
            while (i < k && o[i] != '>') i++;
            c = ' ';
        }
        if (is_space(c)) { if (m && t[m - 1] != ' ') t[m++] = ' '; continue; }
        if (c == 1 && i + 3 < k) {
            unsigned u = (o[i + 1] & 63) << 12 | (o[i + 2] & 63) << 6 | (o[i + 3] & 63);
            memcpy(t + m, o + i, 4); m += 4; i += 3;
            if (u >= 0x400 || (u >= 0xC0 && u < 0x250)) letters++, mark = 1; else other++;
            continue;
        }
        t[m++] = c;
        if ((c >= 'a' && c <= 'z') || c >= 0x80) letters++;
        else if (c >= 'A' && c <= 'Z') letters++, mark = 1;
        else if (c == '-' || c == '_') hy++, other++;
        else { other++; if (c == '.' || c == ',' || c == '!' || c == '?') mark = 1; }
    }
    while (m && t[m - 1] == ' ') m--;
    t[m] = 0;
    free(o);
    for (i = 0; i < m; i++) if (t[i] == ' ') spaces++;
    if (m < 24 || spaces < 3 || !mark || letters * 10 < (letters + other) * 7 || hy * 3 > spaces + 1 ||
        starts_ci(t, "http") || t[0] == '/' || strstr_at(t, "function") || strstr_at(t, "=>") || strstr_at(t, "{") ||
        strstr_at(t, "var(--") || strstr_at(t, "px ")) { free(t); return; }
    for (i = 0; i < m; i++) h = (h ^ (unsigned char)t[i]) * 16777619u;
    for (i = 0; i < jx_nseen; i++) if (jx_seen[i] == h) { free(t); return; }
    if (jx_nseen < 512) jx_seen[jx_nseen++] = h;
    jx_strings++;
    st_outs("<p>");
    for (i = 0; i < m; i++) {
        if (t[i] == 1) {
            char num[12];
            unsigned u = (t[i + 1] & 63) << 12 | (t[i + 2] & 63) << 6 | (t[i + 3] & 63);
            int z = 0;
            do { num[z++] = '0' + u % 10; u /= 10; } while (u);
            st_outs("&#");
            while (z) st_out(num[--z]);
            st_out(';');
            i += 3;
        } else if (t[i] == '<') st_outs("&lt;");
        else st_out(t[i]);
    }
    st_outs("</p>");
    jx_out += m;
    free(t);
}
static void jx_scan(const char *d, int n, int depth)
{
    char key[32] = "";
    int i = 0;
    while (i < n) {
        int j, q;
        if (d[i] != '"') { i++; continue; }
        for (j = i + 1; j < n && d[j] != '"'; j++) if (d[j] == '\\') j++;
        if (j >= n) return;
        for (q = j + 1; q < n && is_space(d[q]); q++) ;
        if (q < n && d[q] == ':') {                       /* a key */
            int l = j - i - 1 < 31 ? j - i - 1 : 31;
            memcpy(key, d + i + 1, l); key[l] = 0;
        } else {
            jx_string(d + i + 1, j - i - 1, key, depth);
            key[0] = 0;
        }
        i = j + 1;
    }
}
static void js_page_text(void)
{
    int had = srclen;
    jx_nseen = jx_out = jx_strings = 0;
    if (st_textn >= 600 && !(jxn && st_textn < 3000)) return;
    st_outs("<div class=\"lx-js\"><hr><p><i>This page draws itself with JavaScript, which LexOS Web doesn't run. "
            "What it says, from the data inside it:</i></p>");
    if (meta_desc[0] && st_textn < 600) {
        int i;
        st_outs("<p><b>");
        for (i = 0; meta_desc[i]; i++) if (meta_desc[i] == '<') st_outs("&lt;"); else st_out(meta_desc[i]);
        st_outs("</b></p>");
        jx_strings++;
        jx_out += strlen(meta_desc);
    }
    if (jx && jxn) jx_scan(jx, jxn, 0);
    if (!jx_strings || (st_textn >= 600 && jx_out < st_textn * 2)) { srclen = had; return; }   /* (nothing, or said already) */
    st_outs("</div>");
}

static void title_scan(void)
{
    int p;
    title[0] = 0;
    for (p = 0; p + 7 < srclen; p++)
        if (src[p] == '<' && starts_ci(src + p + 1, "title") && (src[p + 6] == '>' || src[p + 6] == ' ')) {
            int t = 0;
            while (p < srclen && src[p] != '>') p++;
            p++;
            while (p < srclen && src[p] != '<') {
                char out[3];
                unsigned u = src[p] == '&' ? entity(&p) : next_char(&p);
                int k, m = to_font(is_space(u) ? ' ' : u, out);
                for (k = 0; k < m && t < (int)sizeof title - 1; k++)
                    if (!(out[k] == ' ' && (!t || title[t - 1] == ' '))) title[t++] = out[k];
            }
            while (t && title[t - 1] == ' ') t--;
            title[t] = 0;
            return;
        }
}

static void layout(void)
{
    int p = 0, end = srclen;
    char keep_title[sizeof title];
    free_page();
    left_x = reader ? 96 : MARGIN;
    right_x = W - SBW - (reader ? 96 : MARGIN);
    x = line_left = left_x;
    y = 14;
    line_start = 0;
    pending_space = 0;
    last_gap = 14;
    bold = ital = under = pre = center = head = 0;
    scale = 1;
    cur_link = -1;
    indent = list_depth = ncolor = 0;
    base_left = left_x;
    tb_reset();
    ctrls_free();
    wlen = 0;
    ncssf = 0;
    img_count = 0;
    pi.hidden = pi.imgs = pi.imgs_bad = 0;
    copy(keep_title, title, sizeof keep_title);
    page_bg = reader ? RGB(250, 246, 236) : C_PAGE;
    base_text = reader ? RGB(40, 36, 32) : C_TEXT;
    if (pi.kind == PK_TEXT || view_source) {
        layout_plain();
    } else {
        if (reader) reader_range(&p, &end);
        while (p < end) {
            unsigned char c = src[p];
            if (c == '<') tag(&p);
            else if (c == '&') put_char(entity(&p));
            else put_char(next_char(&p));
        }
        flush_word();
        end_line(0);
    }
    if (!title[0]) copy(title, keep_title, sizeof title);
    doc_h = y + 20;
    scroll = 0;
}

/* ============================================================
 * the window: toolbar, page, scrollbar, status
 * ============================================================ */
#define BTN_Y (BAR_Y + 6)
#define BTN_H 24
static const int btn_x[] = { 8, 38, 68, 98, 128 };
#define ADDR_X 162
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
    static const char *labels[] = { "\x1b", "\x1a", "R", "\x7f", "Aa" };
    int i;
    fill(0, BAR_Y, W, BAR, C_BAR, 0, H);
    fill(0, BAR_Y + BAR - 1, W, 1, C_BAR_LO, 0, H);
    for (i = 0; i < 5; i++) {
        int dim = (i == 0 && hpos <= 0) || (i == 1 && hpos >= nhist - 1), on = i == 4 && reader;
        bevel(btn_x[i], BTN_Y, 26, BTN_H, on ? C_LINK : hover_btn == i && !dim ? C_HOVER : C_BTN);
        text_at(btn_x[i] + (i == 4 ? 5 : 9), BTN_Y + 4, labels[i], on ? C_PAGE : dim ? C_RULE : C_TEXT, ST_BOLD, 16);
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

/* a field, drawn */
static void draw_ctrl(struct item *it, int sy, int top, int bot)
{
    struct ctrl *c = &ctrls[it->text];
    int foc = it->text == focus, i;
    unsigned bd = foc ? C_LINK : RGB(140, 148, 164);
    const char *v = c->val ? c->val : "";
    switch (c->kind) {
    case CT_CHECK: case CT_RADIO:
        fill(it->x, sy, 16, 16, bd, top, bot);
        fill(it->x + 1, sy + 1, 14, 14, RGB(255, 255, 255), top, bot);
        if (c->checked) {
            if (c->kind == CT_RADIO) fill(it->x + 4, sy + 4, 8, 8, C_LINK, top, bot);
            else for (i = 0; i < 8; i++) { fill(it->x + 4 + i, sy + 4 + i, 2, 2, C_TEXT, top, bot); fill(it->x + 11 - i, sy + 4 + i, 2, 2, C_TEXT, top, bot); }
        }
        return;
    case CT_SUBMIT: case CT_BUTTON: case CT_IMAGE: {
        int n = strlen(v), tw;
        fill(it->x, sy, it->w, it->h, RGB(150, 160, 180), top, bot);
        fill(it->x + 1, sy + 1, it->w - 2, it->h - 2, it->text == hover_ctrl ? C_HOVER : RGB(236, 240, 247), top, bot);
        if (n > (it->w - 8) / 8) n = (it->w - 8) / 8;
        tw = n * 8;
        for (i = 0; i < n; i++) glyph(it->x + (it->w - tw) / 2 + i * 8, sy + 4, (unsigned char)v[i], C_TEXT, 1, 0, top, bot);
        return;
    }
    case CT_SELECT: {
        const char *o = c->opts;
        int k;
        fill(it->x, sy, it->w, it->h, bd, top, bot);
        fill(it->x + 1, sy + 1, it->w - 2, it->h - 2, RGB(250, 251, 253), top, bot);
        for (k = 0; o && k < c->sel; k++) { o += strlen(o) + 1; o += strlen(o) + 1; }
        if (o && c->nopt) for (i = 0; o[i] && i < (it->w - 26) / 8; i++) glyph(it->x + 6 + i * 8, sy + 3, (unsigned char)o[i], C_TEXT, 1, 0, top, bot);
        glyph(it->x + it->w - 16, sy + 3, 0x1F, C_GRAY, 1, 0, top, bot);
        return;
    }
    default: {                                           /* text: a line, or lines */
        int cols = (it->w - 10) / 8, n = strlen(v), rows = c->kind == CT_AREA ? (it->h - 8) / 16 : 1;
        int line = 0, col = 0, first = 0, cx = 0, cy = 0;
        fill(it->x, sy, it->w, it->h, bd, top, bot);
        fill(it->x + 1, sy + 1, it->w - 2, it->h - 2, RGB(255, 255, 255), top, bot);
        if (!n && !foc && c->ph[0]) {
            for (i = 0; c->ph[i] && i < cols; i++) glyph(it->x + 5 + i * 8, sy + 3, (unsigned char)c->ph[i], RGB(150, 156, 168), 1, 0, top, bot);
            return;
        }
        if (c->kind != CT_AREA) {                        /* one line: its end, if it's long */
            int st = n > cols - 1 && foc ? n - (cols - 1) : 0;
            for (i = st; i < n && i - st < cols; i++)
                glyph(it->x + 5 + (i - st) * 8, sy + 3, c->kind == CT_PASS ? '*' : (unsigned char)v[i], C_TEXT, 1, 0, top, bot);
            if (foc) fill(it->x + 5 + (n - st) * 8, sy + 3, 2, 16, C_LINK, top, bot);
            return;
        }
        for (i = 0; i <= n; i++) {                       /* (how many lines: the last ones shown) */
            if (i == n) break;
            if (v[i] == '\n' || ++col >= cols) { line++; col = 0; }
        }
        if (line >= rows) first = line - rows + 1;
        line = col = 0;
        for (i = 0; i < n; i++) {
            if (v[i] == '\n') { line++; col = 0; continue; }
            if (line >= first && line < first + rows)
                glyph(it->x + 5 + col * 8, sy + 4 + (line - first) * 16, (unsigned char)v[i], C_TEXT, 1, 0, top, bot);
            if (++col >= cols) { line++; col = 0; }
        }
        cx = col; cy = line - first;
        if (foc && cy >= 0 && cy < rows) fill(it->x + 5 + cx * 8, sy + 4 + cy * 16, 2, 16, C_LINK, top, bot);
    }
    }
}
/* an open <select>'s list, under it */
static void draw_sel_list(int top, int bot)
{
    struct ctrl *c;
    struct item *it;
    const char *o;
    int i, sy, rows;
    if (sel_open < 0 || sel_open >= nctrls) return;
    c = &ctrls[sel_open];
    if (c->item < 0) return;
    it = &items[c->item];
    sy = it->y - scroll + top + it->h;
    rows = c->nopt < 14 ? c->nopt : 14;
    if (sy + rows * 18 > bot) sy = it->y - scroll + top - rows * 18;
    fill(it->x + 3, sy + 3, it->w, rows * 18 + 2, RGB(150, 156, 170), top, bot);
    fill(it->x, sy, it->w, rows * 18 + 2, C_LINK, top, bot);
    fill(it->x + 1, sy + 1, it->w - 2, rows * 18, RGB(255, 255, 255), top, bot);
    o = c->opts;
    for (i = 0; i < c->nopt; i++) {
        int k, first = c->sel >= rows ? c->sel - rows + 1 : 0;
        if (i >= first && i < first + rows) {
            int yy = sy + 1 + (i - first) * 18;
            if (i == c->sel) fill(it->x + 1, yy, it->w - 2, 18, C_HOVER, top, bot);
            for (k = 0; o[k] && k < (it->w - 12) / 8; k++) glyph(it->x + 6 + k * 8, yy + 1, (unsigned char)o[k], C_TEXT, 1, 0, top, bot);
        }
        o += strlen(o) + 1; o += strlen(o) + 1;
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
            else if (it->kind == IT_CTRL) draw_ctrl(it, sy, top, bot);
            else if (it->kind == IT_IMAGE) {
                int r, c;
                for (r = 0; r < it->h; r++) {
                    int yy = sy + r;
                    if (yy < top || yy >= bot) continue;
                    const unsigned short *px = (const unsigned short *)it->pix + r * it->w;
                for (c = 0; c < it->w && it->x + c < W - SBW; c++) {
                    unsigned v = px[c];
                    frame[yy * W + it->x + c] = (v & 0xF800) << 8 | (v & 0xE000) << 3 | (v & 0x07E0) << 5 | (v & 0x0600) >> 1 |
                                                (v & 0x001F) << 3 | (v & 0x001C) >> 2;
                }
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
    draw_sel_list(top, bot);
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
    free(t->css);
    t->css = 0;
    t->src = malloc(srclen + 1);
    if (t->src) {
        memcpy(t->src, src, srclen);
        t->srclen = srclen;
        t->kind = pi.kind; t->cs = cs_mode; t->vs = view_source;
        copy(t->base, base_url, URL_MAX);
        if (css_nrules && !(t->css = css_save())) { free(t->src); t->src = 0; }   /* (no room: read again) */
    }
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
    if (t->src && SRC_ROOM(t->srclen)) {
        memcpy(src, t->src, t->srclen);
        srclen = t->srclen;
        src[srclen] = 0;
        free(t->src); t->src = 0;
        memset(&pi, 0, sizeof pi);
        pi.kind = t->kind; cs_mode = t->cs; view_source = t->vs;
        copy(base_url, t->base, URL_MAX);
        css_restore(t->css);
        free(t->css); t->css = 0;
        pi.kept = srclen;
        if (pi.kind == PK_HTML && !view_source) title_scan();
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
        free(tabs[i].css);
        for (j = i; j < ntabs - 1; j++) tabs[j] = tabs[j + 1];
        ntabs--;
        if (cur_tab > i) cur_tab--;
        return;
    }
    free(tabs[i].src);
    free(tabs[i].css);
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

static void draw_info(void);
static void redraw(void)
{
    draw_tabs();
    draw_bar();
    draw_page();
    if (show_dls) draw_downloads();
    if (show_info) draw_info();
    draw_status();
    gfx_blit(frame);
}

/* ============================================================
 * going places
 * ============================================================ */
/* a page about what went wrong: what it means, in words, and what to
 * try (again; the archive's copy; a search; http:// for https://) */
static void url_enc(char *q, int *n, int max, const char *t, int len);
static void error_page(const char *head, const char *what, const char *hint, const char *where)
{
    char *s = src;
    int web = is_http(where);
    *s = 0;
    append(s, "<title>", src_cap); append(s, head, src_cap);
    append(s, "</title><body><h1>", src_cap); append(s, head, src_cap);
    append(s, "</h1><p>", src_cap); append(s, what, src_cap);
    append(s, "</p><p><b>", src_cap);
    {
        int n = strlen(s), i;
        for (i = 0; where[i] && n < src_cap - 8; i++) {
            if (where[i] == '<') { memcpy(s + n, "&lt;", 4); n += 4; }
            else if (where[i] == '&') { memcpy(s + n, "&amp;", 5); n += 5; }
            else s[n++] = where[i];
        }
        s[n] = 0;
    }
    append(s, "</b></p>", src_cap);
    if (hint && hint[0]) { append(s, "<p>", src_cap); append(s, hint, src_cap); append(s, "</p>", src_cap); }
    if (web) {
        const char *h = where + (is_https(where) ? 8 : 7), *e = h;
        while (*e && *e != '/' && *e != '?' && *e != ':') e++;
        append(s, "<h3>What to try</h3><ul><li><a href=\"", src_cap); append(s, where, src_cap);
        append(s, "\">Try again</a> (or press F5)</li><li><a href=\"https://web.archive.org/web/2/", src_cap); append(s, where, src_cap);
        append(s, "\">The copy in the Internet Archive</a></li>", src_cap);
        if (is_https(where)) {
            append(s, "<li><a href=\"http://", src_cap); append(s, h, src_cap);
            append(s, "\">The same over http://</a> (not encrypted - if the site still has it)</li>", src_cap);
        }
        append(s, "<li><a href=\"https://html.duckduckgo.com/html/?q=", src_cap);
        { int n = strlen(s); url_enc(s, &n, src_cap, h, e - h); s[n] = 0; }
        append(s, "\">Search for this site</a></li></ul>", src_cap);
    }
    append(s, "<hr><p>Pages can be on this disk (<a href=\"/DEMOS/SITE/INDEX.HTM\">/DEMOS/SITE/INDEX.HTM</a>) or on the web, "
              "over <b>http://</b> or <b>https://</b>. Words typed in the address bar are searched for.</p>", src_cap);
    srclen = strlen(src);
}
/* an HTTP code: what it means */
static void error_for_code(int v, char *head, char *what, char *hint, int cap)
{
    char num[8];
    int k = 0, t = v;
    do { num[k++] = '0' + t % 10; t /= 10; } while (t && k < 7);
    copy(head, "The site answered with an error", cap);
    copy(hint, "", cap);
    if (v == 404 || v == 410) { copy(head, "There's no such page", cap); copy(what, "The site is there, but has no page at this address", cap);
        copy(hint, "The link may be old, or the address mistyped. Its <a href=\"/\">first page</a> may lead to where it went.", cap); }
    else if (v == 401 || v == 407) { copy(head, "This page needs a login", cap); copy(what, "The site wants a name and a password for it", cap); }
    else if (v == 403) { copy(head, "The site didn't let us in", cap); copy(what, "The server refuses to show this page", cap);
        copy(hint, "Some sites shut out browsers they don't know, or ones without JavaScript. The archive's copy may still open.", cap); }
    else if (v == 429) { copy(head, "Too many requests", cap); copy(what, "The site asks to wait before asking again", cap); }
    else if (v == 451) { copy(head, "Not available here", cap); copy(what, "The site won't show this page where we are, for legal reasons", cap); }
    else if (v >= 500) { copy(head, "The site has trouble", cap); copy(what, "Something broke on the server's side, not here", cap);
        copy(hint, "It's often over soon: try again in a minute.", cap); }
    else if (v > 0) copy(what, "The server answered, but not with the page", cap);
    else copy(what, "The server's answer wasn't one we could read", cap);
    if (v > 0) {
        append(what, " (", cap);
        while (k) { char one[2] = { num[--k], 0 }; append(what, one, cap); }
        append(what, ")", cap);
    }
    append(what, ".", cap);
}

static void clamp_scroll(void)
{
    int max = doc_h - VIEW_H;
    if (scroll > max) scroll = max;
    if (scroll < 0) scroll = 0;
}

/* a page's kind by its name (on this disk) */
static int kind_by_name(const char *u)
{
    static const char *text[] = { "TXT", "C", "H", "ASM", "CFG", "HG", "BAS", "LOG", "JSON", "CSS", "JS", "XML", "INI", "CSV", "LNK", 0 };
    static const char *pics[] = { "BMP", "PNG", "JPG", "JPEG", "GIF", 0 };
    const char *e = 0, *q;
    int i, n;
    for (q = u; *q && *q != '?' && *q != '#'; q++) { if (*q == '.') e = q + 1; if (*q == '/') e = 0; }
    if (!e) return PK_SNIFF;
    n = q - e;
    if ((n == 3 && starts_ci(e, "htm")) || (n == 4 && starts_ci(e, "html"))) return PK_HTML;
    if ((n == 2 && starts_ci(e, "md")) || (n == 8 && starts_ci(e, "markdown"))) return PK_MD;
    for (i = 0; text[i]; i++) if ((int)strlen(text[i]) == n && starts_ci(e, text[i])) return PK_TEXT;
    for (i = 0; pics[i]; i++) if ((int)strlen(pics[i]) == n && starts_ci(e, pics[i])) return PK_IMAGE;
    return PK_SNIFF;
}

/* the charset: the server's word, the page's <meta>, a BOM - or a guess */
static void pick_charset(void)
{
    int m;
    pi.cs_how = 0;
    cs_mode = CS_UTF8;
    if (pi.cs_hdr[0] && (m = cs_named(pi.cs_hdr)) >= 0) { cs_mode = m; pi.cs_how = 1; return; }
    if (!pi.cs_meta[0] && pi.kind == PK_HTML) {           /* (text as it was: <meta> not read yet) */
        int p;
        for (p = 0; p + 12 < srclen && p < 8192; p++)
            if (starts_ci(src + p, "charset=")) {
                int k = 0, q = p + 8;
                if (src[q] == '"' || src[q] == '\'') q++;
                while (q < srclen && k < 23 && src[q] != '"' && src[q] != '\'' && src[q] != ';' && src[q] != ' ' && src[q] != '>' && src[q] != '/')
                    pi.cs_meta[k++] = lower(src[q++]);
                pi.cs_meta[k] = 0;
                break;
            }
    }
    if (pi.cs_meta[0] && (m = cs_named(pi.cs_meta)) >= 0) { cs_mode = m; pi.cs_how = 2; return; }
    if (srclen >= 3 && (unsigned char)src[0] == 0xEF && (unsigned char)src[1] == 0xBB && (unsigned char)src[2] == 0xBF) { pi.cs_how = 4; return; }
    cs_mode = cs_guess(src, srclen);
    pi.cs_how = 3;
}

/* its <link>ed style sheets (3 at most), read into css.h's rules */
static void load_styles(void)
{
    int i, n = ncss_links < 3 ? ncss_links : 3;
    for (i = 0; i < n; i++) {
        char w[URL_MAX];
        int save_tg = tg, save_pi_css = pi.css_files;
        static char pi_copy[sizeof pi];
        unsigned char *b = 0;
        int k, got;
        resolve(base_url, css_links[i], w);
        memcpy(pi_copy, &pi, sizeof pi);                 /* (the page's own, kept) */
        got = load_cached(w, &b);                        /* (the cache's, if it's there) */
        tg = T_CSS;
        css_begin();
        if (got >= 0 && b) { for (k = 0; k < got; k++) css_feed(b[k]); save_pi_css++; }
        css_end();
        free(b);
        tg = save_tg;
        memcpy(&pi, pi_copy, sizeof pi);
        pi.css_files = save_pi_css;
    }
}

/* a picture or a file, not a page: a page about it */
static void about_page(const char *where)
{
    char *s = src;
    *s = 0;
    if (pi.kind == PK_IMAGE) {
        append(s, "<html><body bgcolor=\"#2a2d34\"><center><img src=\"", src_cap);
        append(s, where, src_cap);
        append(s, "\" alt=\"(this picture couldn't be shown)\"></center></body></html>", src_cap);
    } else {
        char t[32];
        t[0] = 0;
        append(s, "<title>A file, not a page</title><body><h1>A file, not a page</h1><p>This address is ", src_cap);
        append(s, pi.ctype[0] ? pi.ctype : "a file", src_cap);
        if (pi.total > 0) { num_kb(t, pi.total, sizeof t); append(s, " (", src_cap); append(s, t, src_cap); append(s, ")", src_cap); }
        append(s, ".</p><p><b><a href=\"download:", src_cap);
        append(s, where, src_cap);
        append(s, "\">Download it into /DOWNLOADS</a></b></p>", src_cap);
    }
    srclen = strlen(src);
    pi.kind = PK_HTML;
}

/* sites that have a lighter version, one that works without
 * JavaScript: that one (reddit -> old.reddit, a DuckDuckGo or Google
 * search -> DuckDuckGo's HTML one, Wikipedia's articles as they are) */
static int err_shown;                                    /* (this page: ours, about an error) */
static int lighter(char *u)
{
    char host[96], rest[URL_MAX], t[URL_MAX];
    const char *p, *q;
    int n = 0;
    if (!is_http(u)) return 0;
    p = u + (is_https(u) ? 8 : 7);
    while (*p && *p != '/' && *p != '?' && *p != ':' && n < 95) host[n++] = lower(*p++);
    host[n] = 0;
    copy(rest, p, URL_MAX);
    if (!strcmp(host, "reddit.com") || !strcmp(host, "www.reddit.com") || !strcmp(host, "new.reddit.com") || !strcmp(host, "m.reddit.com")) {
        copy(t, "https://old.reddit.com", URL_MAX); append(t, rest, URL_MAX);
    } else if ((!strcmp(host, "duckduckgo.com") || !strcmp(host, "www.duckduckgo.com")) && (q = strstr_at(rest, "q=")) &&
               (q[-1] == '?' || q[-1] == '&')) {
        copy(t, "https://html.duckduckgo.com/html/?", URL_MAX); append(t, q, URL_MAX);
    } else if ((starts_ci(host, "www.google.") || starts_ci(host, "google.")) && starts_ci(rest, "/search") &&
               (q = strstr_at(rest, "q=")) && (q[-1] == '?' || q[-1] == '&')) {
        int k;
        copy(t, "https://html.duckduckgo.com/html/?", URL_MAX); append(t, q, URL_MAX);
        for (k = 35; t[k]; k++) if (t[k] == '&') { t[k] = 0; break; }
    } else if (!strcmp(host, "twitter.com") || !strcmp(host, "x.com") || !strcmp(host, "mobile.twitter.com")) {
        return 0;                                        /* (nothing light left there) */
    } else return 0;
    if (!strcmp(t, u)) return 0;
    copy(u, t, URL_MAX);
    return 1;
}

static void go(const char *to, int remember)
{
    int n, vs = 0;
    char where[URL_MAX], final[URL_MAX];
    copy(where, to, URL_MAX);
    if (!where[0]) return;
    if (starts_ci(where, "view-source:")) { vs = 1; memmove(where, where + 12, strlen(where + 12) + 1); }
    if (!is_http(where) && where[0] != '/' &&
        (starts_ci(where, "www.") || (strlen(where) > 4 && !starts_ci(where + strlen(where) - 4, ".htm") &&
                                     !starts_ci(where + strlen(where) - 5, ".html")))) {
        char t[URL_MAX];                  /* "example.com" -> https:// */
        copy(t, "https://", URL_MAX);
        append(t, where, URL_MAX);
        copy(where, t, URL_MAX);
    }
    if (!vs && is_download(where)) { download(where); return; }
    if (!vs) lighter(where);
    copy(url, where, URL_MAX);
    copy(status, "Loading ", sizeof status);
    append(status, where, sizeof status);
    append(status, " ...", sizeof status);
    hover_link = -1;
    show_info = 0;
    redraw();
    memset(&pi, 0, sizeof pi);
    pi.kind = is_http(where) ? PK_HTML : kind_by_name(where);
    view_source = vs;
    tg = T_PAGE;
    srclen = 0;
    st_reset();
    css_reset();
    ncss_links = 0;
    cache_hits = 0;
    base_url[0] = 0;
    cs_mode = CS_UTF8;
    title[0] = 0;
    n = net_get(where, final);
    free(post_body); post_body = 0;                      /* (a form's, sent) */
    if (n >= 0 && strcmp(final, where)) copy(where, final, URL_MAX);       /* (moved: there) */
    if (!base_url[0]) copy(base_url, where, URL_MAX);
    copy(url, where, URL_MAX);
    if (vs) { char t[URL_MAX]; copy(t, "view-source:", URL_MAX); append(t, where, URL_MAX); copy(url, t, URL_MAX); }
    err_shown = 0;
    if (n < 0 || (pi.code >= 400 && srclen < 16 && pi.kind != PK_IMAGE && pi.kind != PK_FILE)) {
        static char head[80], why[300], hint[400];
        hint[0] = 0;
        if (n == -4) {
            copy(head, "No secure connection", sizeof head);
            copy(why, "The encrypted connection (TLS) didn't work: ", sizeof why); append(why, tls_error, sizeof why);
            copy(hint, "The site may want encryption LexOS doesn't have yet (RSA keys, TLS 1.0/1.1, other curves). "
                       "Try it over http://, or the archive's copy.", sizeof hint);
        } else if (n == -5) {
            copy(head, "Packed in an unknown way", sizeof head);
            copy(why, "The server sent the page packed with ", sizeof why); append(why, pi.cenc, sizeof why);
            append(why, ", which LexOS can't unpack (gzip and deflate it can), even after asking for it unpacked.", sizeof why);
        } else if (n >= 0 || n == -2) error_for_code(pi.code, head, why, hint, sizeof why);
        else if (is_http(where)) {
            copy(head, "No answer", sizeof head);
            copy(why, "The server didn't answer, or its name wasn't found.", sizeof why);
            copy(hint, "Is the network up? (In the terminal: <b>ifconfig</b>, <b>dhcp</b>.) Is the address spelled right?", sizeof hint);
        } else {
            copy(head, "No such file", sizeof head);
            copy(why, "There's no such file on this disk.", sizeof why);
            copy(hint, "Names are like <b>/DEMOS/SITE/INDEX.HTM</b>. Files can show you what's where.", sizeof hint);
        }
        error_page(head, why, hint, where);
        err_shown = 1;
        pi.kind = PK_HTML;
        view_source = 0;
        cs_mode = CS_UTF8;
    } else if (!vs && (pi.kind == PK_IMAGE || pi.kind == PK_FILE)) {
        about_page(where);
        cs_mode = CS_UTF8;
    } else {
        if (pi.kind == PK_SNIFF) pi.kind = PK_HTML;
        src[srclen] = 0;
        pick_charset();
        if (pi.kind == PK_TEXT && is_markdown(where)) pi.kind = PK_MD;
        if (pi.kind == PK_MD && !vs) { markdown(); pi.kind = PK_HTML; }
        if (pi.kind == PK_HTML && !vs) js_page_text();
        if (pi.kind == PK_HTML && !vs && ncss_links) load_styles();
    }
    pi.kept = srclen;
    src[srclen] = 0;
    if (remember) {
        if (hpos < HIST_MAX - 1) hpos++;
        else memmove(hist[0], hist[1], sizeof hist[0] * (HIST_MAX - 1));
        copy(hist[hpos], url, URL_MAX);
        nhist = hpos + 1;
    }
    if (pi.kind == PK_HTML && !view_source) title_scan();
    layout();
    status[0] = 0;
    if (pi.trunc) copy(status, "A big page: shown up to 256KB of it.", sizeof status);
    else if (pi.code >= 400 && !err_shown)
        copy(status, "The server said this page isn't there (or isn't for us).", sizeof status);
    redraw();
    {                                                    /* <meta http-equiv=refresh>: soon - there */
        static int hops;
        char next[URL_MAX];
        if (refresh_to[0] && refresh_wait <= 8 && hops < 3 && !view_source && pi.kind == PK_HTML) {
            resolve(base_url, refresh_to, next);
            if (strcmp(next, url) && is_http(next) == is_http(url)) {
                hops++;
                go(next, 0);
                hops--;
                if (hpos >= 0 && hpos < HIST_MAX) copy(hist[hpos], url, URL_MAX);
            }
        }
    }
}

/* ---- forms: clicks, keys, sending ---- */
static int ctrl_at(int mx, int my)
{
    int i, dy = my - VIEW_Y + scroll;
    for (i = 0; i < nitems; i++) {
        struct item *it = &items[i];
        if (it->kind != IT_CTRL) continue;
        if (mx >= it->x && mx < it->x + it->w && dy >= it->y && dy < it->y + it->h) return it->text;
    }
    return -1;
}
/* the open list: which of its lines is at mx,my (-1 none) */
static int sel_list_at(int mx, int my)
{
    struct ctrl *c;
    struct item *it;
    int sy, rows, first, r;
    if (sel_open < 0 || ctrls[sel_open].item < 0) return -1;
    c = &ctrls[sel_open];
    it = &items[c->item];
    rows = c->nopt < 14 ? c->nopt : 14;
    sy = it->y - scroll + VIEW_Y + it->h;
    if (sy + rows * 18 > VIEW_Y + VIEW_H) sy = it->y - scroll + VIEW_Y - rows * 18;
    if (mx < it->x || mx >= it->x + it->w || my < sy + 1 || my >= sy + 1 + rows * 18) return -1;
    first = c->sel >= rows ? c->sel - rows + 1 : 0;
    r = first + (my - sy - 1) / 18;
    return r < c->nopt ? r : -1;
}
/* s (n bytes) -> q, url-encoded */
static void url_enc(char *q, int *n, int max, const char *t, int len)
{
    int i;
    for (i = 0; i < len && *n < max - 4; i++) {
        unsigned char c = t[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '*')
            q[(*n)++] = c;
        else if (c == ' ') q[(*n)++] = '+';
        else { q[(*n)++] = '%'; q[(*n)++] = "0123456789ABCDEF"[c >> 4]; q[(*n)++] = "0123456789ABCDEF"[c & 15]; }
    }
    q[*n] = 0;
}
/* the font's text -> the page's charset (in out, max) -> its length */
static int font_to_cs(const char *v, char *out, int max)
{
    int i, n = 0;
    for (i = 0; v[i] && n < max - 6; i++) {
        char o[4];
        int k, j;
        if (v[i] == '\n') { out[n++] = '\r'; out[n++] = '\n'; continue; }
        k = uni_cs(font_uni((unsigned char)v[i]), cs_mode, o);
        for (j = 0; j < k; j++) out[n++] = o[j];
    }
    out[n] = 0;
    return n;
}
static void go(const char *to, int remember);
/* form f sent (btn: the button pressed, -1 Enter) */
static void form_submit(int f, int btn)
{
    static char q[16384], enc[VAL_MAX * 4];
    char act[URL_MAX], to[URL_MAX];
    int n = 0, i;
    q[0] = 0;
    for (i = 0; i < nctrls; i++) {
        struct ctrl *c = &ctrls[i];
        const char *v = "";
        int vl;
        if (c->form != f || !c->name[0]) continue;
        switch (c->kind) {
        case CT_CHECK: case CT_RADIO:
            if (!c->checked) continue;
            v = c->raw && *c->raw ? c->raw : "on";
            break;
        case CT_SUBMIT: case CT_IMAGE:
            if (i != btn) continue;
            v = c->raw ? c->raw : "";
            break;
        case CT_BUTTON:
            continue;
        case CT_SELECT: {
            const char *o = c->opts;
            int k;
            if (!o || !c->nopt) continue;
            for (k = 0; k < c->sel; k++) { o += strlen(o) + 1; o += strlen(o) + 1; }
            v = o + strlen(o) + 1;
            break;
        }
        default:
            if (c->edited && c->val) { font_to_cs(c->val, enc, sizeof enc); v = enc; }
            else v = c->raw ? c->raw : "";
        }
        vl = strlen(v);
        if (n) { q[n++] = '&'; q[n] = 0; }
        url_enc(q, &n, sizeof q, c->name, strlen(c->name));
        if (c->kind == CT_IMAGE) { append(q, ".x=1&", sizeof q); n = strlen(q); url_enc(q, &n, sizeof q, c->name, strlen(c->name)); append(q, ".y=1", sizeof q); n = strlen(q); continue; }
        q[n++] = '='; q[n] = 0;
        url_enc(q, &n, sizeof q, v, vl);
    }
    resolve(base_url[0] ? base_url : url, f >= 0 && forms[f].action[0] ? forms[f].action : url, act);
    focus = sel_open = -1;
    if (f >= 0 && forms[f].post) {
        free(post_body);
        post_body = malloc(n + 1);
        if (!post_body) return;
        memcpy(post_body, q, n + 1);
        post_len = n;
        go(act, 1);
        return;
    }
    for (i = 0; act[i]; i++) if (act[i] == '?' || act[i] == '#') { act[i] = 0; break; }
    copy(to, act, URL_MAX);
    append(to, "?", URL_MAX);
    append(to, q, URL_MAX);
    go(to, 1);
}
static void ctrl_click(int ci)
{
    struct ctrl *c = &ctrls[ci];
    int i;
    focus = ci;
    switch (c->kind) {
    case CT_CHECK: c->checked = !c->checked; break;
    case CT_RADIO:
        for (i = 0; i < nctrls; i++)
            if (ctrls[i].kind == CT_RADIO && ctrls[i].form == c->form && !strcmp(ctrls[i].name, c->name)) ctrls[i].checked = 0;
        c->checked = 1;
        break;
    case CT_SELECT: sel_open = sel_open == ci ? -1 : ci; break;
    case CT_SUBMIT: case CT_IMAGE: form_submit(c->form, ci); break;
    }
}
/* a key, with a field chosen -> 1 if it was the field's */
static int ctrl_key(int ch, int sc)
{
    struct ctrl *c;
    int n;
    if (focus < 0 || focus >= nctrls) return 0;
    c = &ctrls[focus];
    if (ch == 27) { focus = sel_open = -1; return 1; }
    if (ch == 9) {                                       /* Tab: the next field */
        int i;
        for (i = 1; i <= nctrls; i++) {
            int k = (focus + i) % nctrls;
            if (ctrls[k].kind != CT_HIDDEN && ctrls[k].item >= 0) { focus = k; break; }
        }
        sel_open = -1;
        return 1;
    }
    if (c->kind == CT_SELECT) {
        if (sc == 0x48 && !ch) { if (c->sel > 0) c->sel--; return 1; }
        if (sc == 0x50 && !ch) { if (c->sel < c->nopt - 1) c->sel++; return 1; }
        if (ch == 13 || ch == ' ') { sel_open = sel_open == focus ? -1 : focus; return 1; }
        return 0;
    }
    if (c->kind == CT_CHECK || c->kind == CT_RADIO || c->kind == CT_SUBMIT || c->kind == CT_IMAGE) {
        if (ch == 13 || ch == ' ') { ctrl_click(focus); return 1; }
        return 0;
    }
    if (c->kind == CT_BUTTON || !c->val) return 0;
    n = strlen(c->val);
    if (ch == 13) {
        if (c->kind == CT_AREA) { if (n < VAL_MAX - 1) { c->val[n] = '\n'; c->val[n + 1] = 0; c->edited = 1; } }
        else form_submit(c->form, -1);
        return 1;
    }
    if (ch == 8) { if (n) c->val[n - 1] = 0; c->edited = 1; return 1; }
    if (ch >= 32 && ch != 127) { if (n < VAL_MAX - 1) { c->val[n] = ch; c->val[n + 1] = 0; c->edited = 1; } return 1; }
    return 0;
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
    if (mx >= btn_x[4] && mx < btn_x[4] + 26) return 7;
    if (mx >= GO_X && mx < GO_X + 36) return 4;
    if (mx >= DL_X && mx < DL_X + 28) return 6;
    if (mx >= ADDR_X && mx < ADDR_X + ADDR_W) return 5;
    return -1;
}

/* the reader on / off: the same page, laid out again */
static void toggle_reader(void)
{
    reader = !reader;
    if (pi.kind == PK_HTML && !view_source) title_scan();
    layout();
    copy(status, reader ? "Reader: the article alone (F9 or Aa: the whole page again)" : "", sizeof status);
    redraw();
}

/* Ctrl+I: what came, and how it was read */
static void info_line(int bx, int *by, const char *label, const char *v1, const char *v2)
{
    char t[160];
    text_at(bx + 10, *by, label, C_GRAY, 0, 110);
    copy(t, v1, sizeof t);
    if (v2) append(t, v2, sizeof t);
    text_at(bx + 120, *by, t, C_TEXT, 0, 440);
    *by += 20;
}
static void num_str(char *t, int v, int size)
{
    char d[12];
    int i = 11;
    d[i] = 0;
    if (v < 0) v = 0;
    do { d[--i] = '0' + v % 10; v /= 10; } while (v);
    append(t, d + i, size);
}
static void draw_info(void)
{
    int bw = 580, bh = 296, bx = (W - SBW - bw) / 2, by = VIEW_Y + 20, ly;
    char t[160];
    static const char *how[] = { " (the default)", " - the server says", " - the page says (<meta>)", " - guessed from its bytes",
                                 " - its byte order mark" };
    static const char *kinds[] = { "a page (HTML)", "text", "a picture", "a file", "Markdown", "?" };
    fill(bx + 3, by + 3, bw, bh, RGB(150, 156, 170), 0, H);
    fill(bx, by, bw, bh, C_BAR_LO, 0, H);
    fill(bx + 1, by + 1, bw - 2, bh - 2, C_PAGE, 0, H);
    text_at(bx + 10, by + 8, "About this page", C_HEAD, ST_BOLD, bw - 20);
    text_at(bx + bw - 130, by + 8, "(Ctrl+I, Esc)", C_GRAY, 0, 120);
    ly = by + 34;
    info_line(bx, &ly, "Address", url, 0);
    t[0] = 0;
    if (is_http(url) || starts_ci(url, "view-source:")) { num_str(t, pi.code, sizeof t); } else copy(t, "(this disk)", sizeof t);
    info_line(bx, &ly, "Answer", t, 0);
    info_line(bx, &ly, "Type", pi.ctype[0] ? pi.ctype : "(not said)", 0);
    copy(t, " - ", sizeof t);
    append(t, kinds[pi.kind <= PK_SNIFF ? pi.kind : 5], sizeof t);
    info_line(bx, &ly, "Shown as", view_source ? "its source, as text" : kinds[pi.kind <= PK_SNIFF ? pi.kind : 5], 0);
    info_line(bx, &ly, "Charset", cs_name(cs_mode), how[pi.cs_how <= 4 ? pi.cs_how : 0]);
    t[0] = 0;
    if (pi.gz) { copy(t, pi.cenc, sizeof t); append(t, ": ", sizeof t); num_kb(t, pi.raw, sizeof t); append(t, " unpacked to ", sizeof t); num_kb(t, pi.body, sizeof t); }
    else { copy(t, pi.cenc[0] ? pi.cenc : "as it is", sizeof t); append(t, ", ", sizeof t); num_kb(t, pi.raw, sizeof t); }
    info_line(bx, &ly, "Sent", t, 0);
    t[0] = 0;
    num_kb(t, pi.kept, sizeof t);
    if (pi.kind == PK_HTML && !view_source) append(t, " kept (scripts, comments, spaces left out)", sizeof t);
    if (pi.trunc) append(t, " - cut off: too big", sizeof t);
    info_line(bx, &ly, "Kept", t, 0);
    t[0] = 0;
    num_str(t, css_nrules, sizeof t);
    append(t, " rules; files read: ", sizeof t);
    num_str(t, pi.css_files, sizeof t);
    append(t, " of ", sizeof t);
    num_str(t, ncss_links, sizeof t);
    info_line(bx, &ly, "Styles", t, 0);
    t[0] = 0;
    num_str(t, pi.hidden, sizeof t);
    append(t, " parts not shown (hidden by the page)", sizeof t);
    info_line(bx, &ly, "Hidden", t, 0);
    t[0] = 0;
    num_str(t, cache_hits, sizeof t);
    append(t, " from /TMP/WEB (F5: all read again)", sizeof t);
    info_line(bx, &ly, "Cache", t, 0);
    t[0] = 0;
    num_str(t, pi.imgs, sizeof t);
    append(t, " shown, ", sizeof t);
    num_str(t, pi.imgs_bad, sizeof t);
    append(t, " not (at most 64 read)", sizeof t);
    info_line(bx, &ly, "Pictures", t, 0);
    t[0] = 0;
    num_str(t, nlinks, sizeof t);
    append(t, " links, ", sizeof t);
    num_str(t, nitems, sizeof t);
    append(t, " pieces laid out", sizeof t);
    info_line(bx, &ly, "Laid out", t, 0);
}

/* what was typed in the address bar -> an address: words (a space in
 * them, or no dot) are a search (DuckDuckGo's page without scripts);
 * letters past ASCII in an address: as UTF-8, %-encoded */
static void addr_typed(char *u)
{
    int i, dot = 0, sp = 0, n = 0;
    char t[URL_MAX];
    for (i = 0; u[i]; i++) { if (u[i] == '.' || u[i] == ':' || u[i] == '/') dot = 1; if (u[i] == ' ') sp = 1; }
    while (*u == ' ') memmove(u, u + 1, strlen(u));
    if (!u[0]) return;
    if (!is_http(u) && !starts_ci(u, "view-source:") && u[0] != '/' && (sp || !dot)) {
        static char utf[URL_MAX];
        int k = 0;
        for (i = 0; u[i] && k < URL_MAX - 5; i++) { char o[4]; int m = uni_cs(font_uni((unsigned char)u[i]), CS_UTF8, o), j; for (j = 0; j < m; j++) utf[k++] = o[j]; }
        utf[k] = 0;
        copy(t, "https://html.duckduckgo.com/html/?q=", URL_MAX);
        n = strlen(t);
        url_enc(t, &n, URL_MAX, utf, k);
        copy(u, t, URL_MAX);
        return;
    }
    for (i = 0; u[i] && n < URL_MAX - 10; i++) {
        unsigned char c = u[i];
        if (c < 0x80) { t[n++] = c; continue; }
        {
            char o[4];
            int m = uni_cs(font_uni(c), CS_UTF8, o), j;
            for (j = 0; j < m; j++) { t[n++] = '%'; t[n++] = "0123456789ABCDEF"[(unsigned char)o[j] >> 4]; t[n++] = "0123456789ABCDEF"[o[j] & 15]; }
        }
    }
    t[n] = 0;
    copy(u, t, URL_MAX);
}
/* a search's results lead through the search's own address
 * (duckduckgo.com/l/?uddg=...): straight there instead */
static void unwrap_link(char *to)
{
    const char *u;
    char t[URL_MAX];
    int n = 0;
    if (!strstr_ci(to, "duckduckgo.com/l/?") || !(u = strstr_at(to, "uddg="))) return;
    for (u += 5; *u && *u != '&' && n < URL_MAX - 1; u++) {
        if (*u == '%' && hexval(u[1]) >= 0 && hexval(u[2]) >= 0) { t[n++] = hexval(u[1]) * 16 + hexval(u[2]); u += 2; }
        else t[n++] = *u == '+' ? ' ' : *u;
    }
    t[n] = 0;
    if (is_http(t)) copy(to, t, URL_MAX);
}

static void press(int b)
{
    if (b == 0 && hpos > 0) { hpos--; go(hist[hpos], 0); }
    else if (b == 1 && hpos < nhist - 1) { hpos++; go(hist[hpos], 0); }
    else if (b == 2) { int s = scroll; cache_reload = 1; go(url, 0); cache_reload = 0; scroll = s; clamp_scroll(); redraw(); }
    else if (b == 3) go(home, 1);
    else if (b == 4) { editing = 0; addr_typed(edit_url); go(edit_url, 1); }
    else if (b == 5 && !editing) { editing = 1; edit_fresh = 1; copy(edit_url, url, URL_MAX); redraw(); }
    else if (b == 6) { show_dls = !show_dls; redraw(); }
    else if (b == 7) toggle_reader();
}

int main(int argc, char **argv)
{
    int m[4], was_down = 0, drag = -1, drag_scroll = 0;
    if (gfx_mode_ex(W, H, 32) < 0) { puts("browser: needs 800x600 in 32 bits\n"); return 1; }
    if (!SRC_ROOM(64 * 1024)) { puts("browser: no memory\n"); return 1; }
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
                if (ch == 13) { editing = 0; addr_typed(edit_url); go(edit_url, 1); }
                else if (ch == 27) editing = 0;
                else if (ch == 8) { if (edit_fresh) edit_url[0] = 0; else if (l) edit_url[l - 1] = 0; edit_fresh = 0; }
                else if (ch >= 32 && ch != 127 && l < URL_MAX - 1) {
                    if (edit_fresh) { l = 0; edit_fresh = 0; }   /* (all chosen: replaced) */
                    edit_url[l] = ch;
                    edit_url[l + 1] = 0;
                }
                changed = 1;
            } else if (focus >= 0 && ctrl_key(ch, sc)) { changed = 1;
            } else if (ch == 27 && show_info) { show_info = 0; changed = 1; }
            else if (ch == 27) break;
            else if (ch == 21) {                                            /* Ctrl+U: its source */
                char t[URL_MAX];
                if (!starts_ci(url, "view-source:") && url[0]) { copy(t, "view-source:", URL_MAX); append(t, url, URL_MAX); tab_new(t); }
                continue;
            }
            else if (ch == 20) { tab_new(home); continue; }                 /* Ctrl+T */
            else if (ch == 19) {                                            /* Ctrl+S: this page, kept */
                if (starts_ci(url, "view-source:") && is_http(url + 12)) download(url + 12);
                else if (is_http(url)) download(url);
                else { copy(status, "It's on this disk already.", sizeof status); changed = 1; }
            }
            else if (ch == 23) { tab_close(cur_tab); changed = 1; }         /* Ctrl+W */
            else if (ch == 9 && keydown(KEY_CTRL) && (sc == 0x17)) { show_info = !show_info; changed = 1; }   /* Ctrl+I */
            else if (ch == 9 && keydown(KEY_CTRL)) { tab_go((cur_tab + 1) % ntabs); changed = 1; }
            else if (ch == 9 || ch == 12) { press(5); }
            else if (ch == 8) press(0);
            else if (sc == 0x3F) press(2);                    /* F5 */
            else if (sc == 0x43) toggle_reader();             /* F9: the reader */
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
            {
                int hc = my >= VIEW_Y && my < VIEW_Y + VIEW_H && mx < W - SBW ? ctrl_at(mx, my) : -1;
                if (hc != hover_ctrl) { hover_ctrl = hc; changed = 1; }
            }
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
                } else if (show_info) { show_info = 0; changed = 1;
                } else if (sel_open >= 0) {                         /* an open list: a line of it */
                    int o = sel_list_at(mx, my);
                    if (o >= 0) ctrls[sel_open].sel = o;
                    sel_open = -1;
                    changed = 1;
                } else if (my >= VIEW_Y && my < VIEW_Y + VIEW_H && ctrl_at(mx, my) >= 0) {
                    editing = 0;
                    ctrl_click(ctrl_at(mx, my));
                    changed = 1;
                } else if (hl >= 0 && starts_ci(lpool + link_off[hl], "download:")) {
                    download(lpool + link_off[hl] + 9);
                    was_down = down;
                    continue;
                } else if (hl >= 0) {
                    char to[URL_MAX];
                    editing = 0;
                    resolve(base_url[0] ? base_url : url, lpool + link_off[hl], to);
                    unwrap_link(to);
                    if (keydown(KEY_CTRL)) tab_new(to);             /* Ctrl: a new tab */
                    else go(to, 1);
                    was_down = down;
                    continue;
                } else {
                    if (editing) { editing = 0; changed = 1; }
                    if (focus >= 0) { focus = -1; changed = 1; }
                }
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
