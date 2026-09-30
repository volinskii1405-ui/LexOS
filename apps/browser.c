/* browser.c - LexOS Web: a web browser in a window.
 *
 *   run browser.app [address]
 *
 * Opens pages from LexOS's own disk (/DEMOS/SITE/INDEX.HTM - the start
 * page) or from the web over plain http:// (its own HTTP/1.1 on the
 * kernel's TCP: tcp_open() and the rest). It knows the HTML a simple
 * page needs: headings, paragraphs, line breaks, bold/italic/underlined
 * text, links, lists (bullets and numbers), <pre>, <hr>, <blockquote>, <center>,
 * tables as rows of cells, <font color>, <body bgcolor>, and pictures -
 * <img> of .BMP (8, 24 or 32 bits), .PNG (png.h), .JPG (jpeg.h) and
 * .GIF (gif.h), up to 16 a page. Text is shown in LexOS's font (Russian
 * and Spanish letters too, the rest as near as it can be).
 *
 * So that no page comes out as gibberish: gzip'd or deflated pages are
 * unpacked (inflate.h); the charset is the server's, the <meta>'s, a
 * BOM's, or guessed from the bytes (UTF-8, windows-1251, KOI8-R, CP866,
 * ISO-8859-5, windows-1252). A page is stripped as it comes (scripts,
 * SVG, comments, most attributes left out), so a big one still fits.
 * A little CSS (css.h): what's hidden stays hidden; bold, italic,
 * colors, centering, the background. JSON and text are shown as text,
 * a picture as a picture, the rest is offered as a download.
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

#define SRC_MAX (256 * 1024)
#define ITEMS_MAX 4500                    /* (words run together: a line's worth each) */
#define POOL_MAX (160 * 1024)
#define LINKS_MAX 600
#define LPOOL_MAX (40 * 1024)
#define URL_MAX 240
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
static int view_source, reader;                          /* (the page's source; the reader) */

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
    {                                                    /* as themselves, or near it */
        static const struct { unsigned short u; char t[4]; } near[] = {
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
            npool + n + 1 <= POOL_MAX) {
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
#define TBUF_MAX (1024 * 1024)                           /* a picture: this big at most */
static char ph[HDR_MAX + 1];                             /* the headers */
static int ph_n, ph_body, ph_chunked, ph_cstate, ph_cleft, ph_stop;
static char ph_moved[URL_MAX];
static unsigned char *zbuf;                              /* gzip'd: gathered, then unpacked */
static int zn, zcap;
static char css_links[4][URL_MAX];
static int ncss_links;
static char base_url[URL_MAX];                           /* <base href>, or the page's address */
static unsigned progress_at;

/* ---- the HTML made smaller as it comes (T_PAGE, PK_HTML) ---- */
enum { SS_TEXT, SS_TAG, SS_SKIP, SS_CSS, SS_COMMENT, SS_GT };
static int st_state, st_pre, st_space, st_q, st_last, st_match, st_tn;
static char st_tag[3072], st_end[12];
static void st_out(int c) { if (srclen < SRC_MAX) src[srclen++] = c; else pi.trunc = 1; }
static void st_outs(const char *t) { while (*t) st_out(*t++); }
static void st_reset(void)
{
    st_state = SS_TEXT; st_pre = st_q = st_last = st_match = st_tn = 0; st_space = 1;
}
static const char *st_keep[] = { "href", "src", "data-src", "alt", "title", "class", "id", "style", "hidden",
    "color", "bgcolor", "value", "type", "rel", "name", "content", "charset", "http-equiv", "open", "role",
    "aria-hidden", "start", "media", 0 };
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
        char rel[32] = "", href[URL_MAX] = "", media[32] = "";
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
    if (pi.gz) {                                         /* gathered, unpacked at the end - */
        if (!zbuf) {                                     /* in the frame's page part, drawn */
            zbuf = (unsigned char *)(frame + VIEW_Y * W);  /* anew once it's in (1.6MB) */
            zcap = VIEW_H * W * 4;
        }
        if (zn + n > zcap) { pi.trunc = 1; return 1; }
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

/* one try at u: 0 had it, 1 moved (ph_moved), -1 no connection, -4 TLS */
static int net_try(const char *u)
{
    char host[URL_MAX], path[URL_MAX];
    const char *p = u + (is_https(u) ? 8 : 7);
    int port = is_https(u) ? 443 : 80, n = 0;
    static const char *hdrs_page = "User-Agent: Mozilla/5.0 (compatible; LexOS-Web/2.0)\r\n"
                                   "Accept: text/html,application/xhtml+xml,*/*;q=0.8\r\n"
                                   "Accept-Language: ru,en;q=0.8,es;q=0.6\r\nAccept-Encoding: gzip, deflate\r\n";
    static const char *hdrs_plain = "User-Agent: Mozilla/5.0 (compatible; LexOS-Web/2.0)\r\nAccept: */*\r\nAccept-Encoding: identity\r\n";
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
    if (is_https(u)) {
        static char none[4];
        tls_headers = tg == T_PAGE ? hdrs_page : hdrs_plain;
        tls_sink = ph_sink;
        n = tls_get(host, port, path, none, 0);
        tls_sink = 0;
        if (n < 0 && !ph_body && strcmp(tls_error, "Stopped.")) return -4;
    } else {
        static char req[URL_MAX * 2 + 600];
        static unsigned char piece[4096];
        if (tcp_open(host, port) < 0) return -1;
        copy(req, "GET ", sizeof req);
        append(req, path, sizeof req);
        append(req, " HTTP/1.1\r\nHost: ", sizeof req);
        append(req, host, sizeof req);
        append(req, "\r\n", sizeof req);
        append(req, tg == T_PAGE ? hdrs_page : hdrs_plain, sizeof req);
        append(req, "Connection: close\r\n\r\n", sizeof req);
        tcp_send(req, strlen(req));
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
    for (tries = 0; tries < 6; tries++) {
        int kind = pi.kind;
        pi.raw = pi.body = pi.gz = 0; pi.cenc[0] = 0; pi.ctype[0] = 0; pi.cs_hdr[0] = 0; pi.total = 0;
        if (tg == T_PAGE) { srclen = 0; pi.trunc = 0; st_reset(); pi.kind = kind; }
        if (tg == T_BUF) tlen = 0;
        zn = 0;
        r = net_try(u);
        if (r != 1) break;
        {
            char moved[URL_MAX];
            resolve(u, ph_moved, moved);
            copy(u, moved, URL_MAX);
        }
        if (!is_http(u)) { r = -2; break; }
    }
    if (r == 1) r = -2;
    if (r >= 0 && zn) {                                  /* gzip'd: unpacked now */
        int z = pi.gz == 1 ? gunzip(zbuf, zn, zb_put) : zinflate(zbuf, zn, zb_put);
        if (z < 0 && !pi.body) r = -2;
    }
    zbuf = 0; zn = zcap = 0;
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

#define IMG_MAX_PAGE 16                   /* pictures read for a page, at most */
/* a picture's 0xRRGGBB pixels -> 16-bit ones (5-6-5) in the same block,
 * the block's other half given back to malloc */
static void to16(unsigned *pix, int n)
{
    unsigned short *o = (unsigned short *)pix;
    struct lx_block *b = (struct lx_block *)pix - 1;
    int i, need;
    for (i = 0; i < n; i++) {
        unsigned c = pix[i];
        o[i] = (c >> 8 & 0xF800) | (c >> 5 & 0x07E0) | (c >> 3 & 0x001F);
    }
    need = (n * 2 + 15) & ~15;
    if (b->size >= (size_t)need + sizeof *b + 64) {       /* (split: the rest free) */
        struct lx_block *r = (struct lx_block *)((char *)(b + 1) + need);
        r->size = b->size - need - sizeof *b;
        r->free = 1;
        r->next = b->next;
        b->next = r;
        b->size = need;
    }
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
            n = load_auto(where, &buf);
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

static int strstr_ci(const char *s, const char *w)
{
    for (; *s; s++) if (starts_ci(s, w)) return 1;
    return 0;
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
    (void)p;
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
    if (!strcmp(name, "body")) { if (!closing && attr("bgcolor") && !reader) page_bg = parse_color(attr("bgcolor"), page_bg); return; }
    if (!strcmp(name, "img")) {                                 /* (lazy ones: data-src the real one) */
        const char *s = attr("src"), *ds = attr("data-src");
        if (ds && *ds && (!s || !*s || starts_ci(s, "data:") || strstr_ci(s, "blank") || strstr_ci(s, "placeholder") ||
                          strstr_ci(s, "lazy") || strstr_ci(s, "spacer") || strstr_ci(s, "pixel"))) s = ds;
        if (s && *s) emit_image(s, attr("alt"));
        return;
    }
    if (!strcmp(name, "input") || !strcmp(name, "button") || !strcmp(name, "select") || !strcmp(name, "textarea")) {
        const char *v = attr("value");
        if (!closing && v && *v && strcmp(attr("type") ? attr("type") : "", "hidden")) {
            pending_space = 1; put_char('['); put_attr_text(v); put_char(']'); flush_word();
        }
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
    if (t->src) {
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
        resolve(base_url, css_links[i], w);
        memcpy(pi_copy, &pi, sizeof pi);                 /* (the page's own, kept) */
        tg = T_CSS;
        css_begin();
        if (net_get(w, 0) >= 0) save_pi_css++;
        css_end();
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
        append(s, "<html><body bgcolor=\"#2a2d34\"><center><img src=\"", SRC_MAX);
        append(s, where, SRC_MAX);
        append(s, "\" alt=\"(this picture couldn't be shown)\"></center></body></html>", SRC_MAX);
    } else {
        char t[32];
        t[0] = 0;
        append(s, "<title>A file, not a page</title><body><h1>A file, not a page</h1><p>This address is ", SRC_MAX);
        append(s, pi.ctype[0] ? pi.ctype : "a file", SRC_MAX);
        if (pi.total > 0) { num_kb(t, pi.total, sizeof t); append(s, " (", SRC_MAX); append(s, t, SRC_MAX); append(s, ")", SRC_MAX); }
        append(s, ".</p><p><b><a href=\"download:", SRC_MAX);
        append(s, where, SRC_MAX);
        append(s, "\">Download it into /DOWNLOADS</a></b></p>", SRC_MAX);
    }
    srclen = strlen(src);
    pi.kind = PK_HTML;
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
    base_url[0] = 0;
    cs_mode = CS_UTF8;
    title[0] = 0;
    n = net_get(where, final);
    if (n >= 0 && strcmp(final, where)) copy(where, final, URL_MAX);       /* (moved: there) */
    if (!base_url[0]) copy(base_url, where, URL_MAX);
    copy(url, where, URL_MAX);
    if (vs) { char t[URL_MAX]; copy(t, "view-source:", URL_MAX); append(t, where, URL_MAX); copy(url, t, URL_MAX); }
    if (n < 0 || (pi.code >= 400 && srclen < 16 && pi.kind != PK_IMAGE && pi.kind != PK_FILE)) {
        static char why[200];
        if (n == -4) { copy(why, "The encrypted connection (TLS 1.3) didn't work: ", sizeof why); append(why, tls_error, sizeof why); }
        else if (n >= 0 || n == -2) {
            char c[8];
            int k = 0, v = pi.code;
            copy(why, "The server answered, but not with the page", sizeof why);
            if (v > 0) {
                append(why, " (", sizeof why);
                do { c[k++] = '0' + v % 10; v /= 10; } while (v && k < 7);
                while (k) { char one[2] = { c[--k], 0 }; append(why, one, sizeof why); }
                append(why, ")", sizeof why);
            }
            append(why, ".", sizeof why);
        } else copy(why, is_http(where) ? "No answer - is the network up? (ifconfig, dhcp)" : "There's no such file on this disk.", sizeof why);
        error_page(why, where);
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
    else if (pi.code >= 400) copy(status, "The server said this page isn't there (or isn't for us).", sizeof status);
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
    int bw = 580, bh = 272, bx = (W - SBW - bw) / 2, by = VIEW_Y + 20, ly;
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
    num_str(t, pi.imgs, sizeof t);
    append(t, " shown, ", sizeof t);
    num_str(t, pi.imgs_bad, sizeof t);
    append(t, " not (at most 16 read)", sizeof t);
    info_line(bx, &ly, "Pictures", t, 0);
    t[0] = 0;
    num_str(t, nlinks, sizeof t);
    append(t, " links, ", sizeof t);
    num_str(t, nitems, sizeof t);
    append(t, " pieces laid out", sizeof t);
    info_line(bx, &ly, "Laid out", t, 0);
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
    else if (b == 7) toggle_reader();
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
                } else if (hl >= 0 && starts_ci(lpool + link_off[hl], "download:")) {
                    download(lpool + link_off[hl] + 9);
                    was_down = down;
                    continue;
                } else if (hl >= 0) {
                    char to[URL_MAX];
                    editing = 0;
                    resolve(base_url[0] ? base_url : url, lpool + link_off[hl], to);
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
