/* paint.c - LexOS Paint: drawing in a window of its own, saved as .BMP
 * or .PNG.
 *
 *   run paint.app [picture.bmp|.png]      (Files: Edit in Paint)
 *
 * Tools (a key each): Pencil P, Brush B, Eraser E, Line L, Rectangle R,
 * Box (filled) X, Oval O, Disc (filled) D, Fill F, Pick a color K.
 * The left button draws in the first color, the right in the second;
 * a palette color, clicked: left - the first, right - the second.
 * Shift makes a line straight (45 degrees) and a rectangle or oval a
 * square or circle. [ and ] (or - and +) the size. The canvas's bottom
 * right corner drags to resize it; the wheel scrolls (Shift: sideways).
 *
 *   Ctrl+N new   Ctrl+O open   Ctrl+S save   Ctrl+Shift+S save as
 *   Ctrl+Z undo  Ctrl+Y redo   Delete clears  Ctrl+Q quit
 *
 * The picture is kept as 16-bit color (5-6-5) - up to 800x600 - to
 * leave room for the undo steps (each packed as runs of one color). It
 * opens 8-, 24- and 32-bit uncompressed .BMPs and any .PNG (png.h;
 * bigger than 800x600: shrunk), and saves 24-bit BMPs or - a name
 * ending in .PNG - PNGs (deflate.h, a piece at a time). */
#include "lexos.h"
#include "png.h"
#include "deflate.h"

#define W 800
#define H 600
#define TOOL_H 44
#define PAL_H 46
#define STATUS_H 22
#define AREA_Y TOOL_H
#define AREA_H (H - TOOL_H - PAL_H - STATUS_H)
#define PAL_Y (H - STATUS_H - PAL_H)
#define MARGIN 6
#define CMAX_W 800
#define CMAX_H 600
#define PATH_MAX 96
#define FIELD_MAX 80
#define UNDO_MAX 24
#define FILL_STACK 16384

#define C_BG      RGB(255, 255, 255)
#define C_TEXT    RGB(28, 30, 36)
#define C_BAR     RGB(226, 232, 242)
#define C_BAR_LO  RGB(170, 180, 198)
#define C_BTN     RGB(248, 250, 253)
#define C_HOVER   RGB(206, 222, 250)
#define C_ON      RGB(170, 200, 246)
#define C_AREA    RGB(160, 168, 184)
#define C_STATUS  RGB(236, 238, 242)
#define C_GRAY    RGB(110, 116, 128)
#define C_ACCENT  RGB(40, 90, 200)
#define C_SEL     RGB(184, 212, 250)

enum { T_PENCIL, T_BRUSH, T_ERASER, T_LINE, T_RECT, T_BOX, T_OVAL, T_DISC, T_FILL, T_PICK, NTOOLS };
static const char *tool_name[NTOOLS] = {
    "Pencil", "Brush", "Eraser", "Line", "Rectangle", "Box", "Oval", "Disc", "Fill", "Pick a color"
};
static const char tool_key[NTOOLS] = { 'P', 'B', 'E', 'L', 'R', 'X', 'O', 'D', 'F', 'K' };
static const int sizes[4] = { 1, 3, 6, 11 };

static const unsigned palette[28] = {
    RGB(0, 0, 0), RGB(128, 128, 128), RGB(128, 0, 0), RGB(128, 128, 0), RGB(0, 128, 0),
    RGB(0, 128, 128), RGB(0, 0, 128), RGB(128, 0, 128), RGB(128, 128, 64), RGB(0, 64, 64),
    RGB(0, 128, 255), RGB(0, 64, 128), RGB(128, 0, 255), RGB(128, 64, 0),
    RGB(255, 255, 255), RGB(192, 192, 192), RGB(255, 0, 0), RGB(255, 255, 0), RGB(0, 255, 0),
    RGB(0, 255, 255), RGB(0, 0, 255), RGB(255, 0, 255), RGB(255, 255, 128), RGB(0, 255, 128),
    RGB(128, 255, 255), RGB(128, 128, 255), RGB(255, 0, 128), RGB(255, 128, 64)
};

static unsigned frame[W * H];
static unsigned short canvas[CMAX_W * CMAX_H];
static unsigned char glyphs[4096];
static int cw = 640, ch = 400;            /* the picture's size */
static int vx, vy;                        /* scrolled by */
static int tool = T_BRUSH, size_i = 1;
static unsigned fg = RGB(0, 0, 0), bg = RGB(255, 255, 255);
static char path[PATH_MAX], name[20] = "UNTITLED.BMP";
static char status[120];
static int dirty, quitting, hover = -1;

/* undo / redo: the picture before each change, packed */
struct snap { unsigned short *runs; int n, w, h; };
static struct snap undo[UNDO_MAX], redo[UNDO_MAX];
static int nundo, nredo;

/* dialogs */
#define DLG_NONE 0
#define DLG_OPEN 1
#define DLG_SAVE 2
#define DLG_ASK  3                        /* save changes? */
static int dlg, ask_then;                 /* after DLG_ASK: 1 new, 2 open, 3 quit */
static char dlg_dir[PATH_MAX], dlg_name[FIELD_MAX];
static char last_dir[PATH_MAX] = "/DESKTOP";
static struct lx_dirent dents[200];
static int ndents, dlg_scroll, dlg_sel = -1, dlg_fresh;

/* ============================================================
 * little helpers
 * ============================================================ */
static int upper(int c) { return c >= 'a' && c <= 'z' ? c - 32 : c; }
static void copy(char *d, const char *s, int n) { int i = 0; while (s[i] && i < n - 1) { d[i] = s[i]; i++; } d[i] = 0; }
static void append(char *d, const char *s, int n) { int l = strlen(d); copy(d + l, s, n - l); }
static void append_num(char *d, int v, int n)
{
    char b[12]; int i = 11; unsigned u = v < 0 ? -v : v;
    b[i] = 0;
    do { b[--i] = '0' + u % 10; u /= 10; } while (u);
    if (v < 0) b[--i] = '-';
    append(d, b + i, n);
}
static int ends_ci(const char *s, const char *e)
{
    int ls = strlen(s), le = strlen(e), i;
    if (le > ls) return 0;
    for (i = 0; i < le; i++) if (upper(s[ls - le + i]) != upper(e[i])) return 0;
    return 1;
}
static void say(const char *s) { copy(status, s, sizeof status); }
static int iabs(int v) { return v < 0 ? -v : v; }
static int shift(void) { return keydown(KEY_LSHIFT) || keydown(KEY_RSHIFT); }

static unsigned short to565(unsigned c)
{ return (unsigned short)(((c >> 8) & 0xF800) | ((c >> 5) & 0x07E0) | ((c >> 3) & 0x001F)); }
static unsigned from565(unsigned short p)
{
    unsigned r = (p >> 11) & 31, g = (p >> 5) & 63, b = p & 31;
    return RGB(r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2);
}

/* ============================================================
 * drawing the window
 * ============================================================ */
static void fill(int x, int y, int w, int h, unsigned c)
{
    int i, j;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > W) w = W - x;
    if (y + h > H) h = H - y;
    for (j = 0; j < h; j++) {
        unsigned *p = frame + (y + j) * W + x;
        for (i = 0; i < w; i++) p[i] = c;
    }
}
static void glyph(int x, int y, unsigned char c, unsigned col)
{
    int r, b;
    const unsigned char *g = glyphs + c * 16;
    if (x < 0 || x > W - 8 || y < 0 || y > H - 16) return;
    for (r = 0; r < 16; r++) {
        unsigned *p = frame + (y + r) * W + x;
        for (b = 0; b < 8; b++) if (g[r] & (0x80 >> b)) p[b] = col;
    }
}
static void text(int x, int y, const char *t, unsigned c, int maxw)
{
    while (*t && maxw >= 8) { glyph(x, y, (unsigned char)*t++, c); x += 8; maxw -= 8; }
}
static void button(int x, int y, int w, int h, const char *label, int lit)
{
    fill(x, y, w, h, C_BAR_LO);
    fill(x + 1, y + 1, w - 2, h - 2, lit ? C_HOVER : C_BTN);
    text(x + (w - 8 * (int)strlen(label)) / 2, y + (h - 16) / 2, label, C_TEXT, w);
}
static void fpix(int x, int y, unsigned c)
{
    if (x >= 0 && x < W && y >= 0 && y < H) frame[y * W + x] = c;
}

/* ============================================================
 * shapes - through a plot function: the canvas's, or the window's
 * (a shape being dragged, over the picture) - so both draw the same
 * ============================================================ */
typedef void (*plot_fn)(int x, int y, unsigned c);

static void cplot(int x, int y, unsigned c)          /* into the picture */
{
    if (x >= 0 && x < cw && y >= 0 && y < ch) canvas[y * cw + x] = to565(c);
}
static int cx0(void) { return MARGIN - vx; }             /* the picture's corner */
static int cy0(void) { return AREA_Y + MARGIN - vy; }
static void pplot(int x, int y, unsigned c)          /* a preview, on screen */
{
    int sx, sy;
    if (x < 0 || x >= cw || y < 0 || y >= ch) return;
    sx = cx0() + x; sy = cy0() + y;
    if (sy < AREA_Y || sy >= AREA_Y + AREA_H || sx < 0 || sx >= W) return;
    frame[sy * W + sx] = c;
}

static void stamp(plot_fn plot, int x, int y, int s, unsigned c, int square)
{
    int i, j, r;
    if (s <= 1) { plot(x, y, c); return; }
    r = s / 2;
    for (j = -r; j <= s - 1 - r; j++)
        for (i = -r; i <= s - 1 - r; i++) {
            if (!square) {
                int di = 2 * i - (s % 2 ? 0 : -1), dj = 2 * j - (s % 2 ? 0 : -1);
                if (di * di + dj * dj > s * s) continue;
            }
            plot(x + i, y + j, c);
        }
}
static void line(plot_fn plot, int x0, int y0, int x1, int y1, int s, unsigned c, int square)
{
    int dx = iabs(x1 - x0), dy = -iabs(y1 - y0);
    int sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, e = dx + dy;
    for (;;) {
        stamp(plot, x0, y0, s, c, square);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * e;                          /* (taken once, before either step) */
        if (e2 >= dy) { e += dy; x0 += sx; }
        if (e2 <= dx) { e += dx; y0 += sy; }
    }
}
static void order(int *a, int *b) { if (*a > *b) { int t = *a; *a = *b; *b = t; } }
static void rect(plot_fn plot, int x0, int y0, int x1, int y1, int s, unsigned c, int filled)
{
    int x, y;
    order(&x0, &x1); order(&y0, &y1);
    if (filled) {
        for (y = y0; y <= y1; y++) for (x = x0; x <= x1; x++) plot(x, y, c);
        return;
    }
    line(plot, x0, y0, x1, y0, s, c, 1);
    line(plot, x1, y0, x1, y1, s, c, 1);
    line(plot, x1, y1, x0, y1, s, c, 1);
    line(plot, x0, y1, x0, y0, s, c, 1);
}
/* an oval inside the box: row by row, each row's half width; the edge
 * joins one row's end to the next one's, so it has no gaps */
static void oval(plot_fn plot, int x0, int y0, int x1, int y1, int s, unsigned c, int filled)
{
    double cxd, cyd, a, b;
    int y, prev_l = 0, prev_r = 0, first = 1;
    order(&x0, &x1); order(&y0, &y1);
    cxd = (x0 + x1) / 2.0; cyd = (y0 + y1) / 2.0;
    a = (x1 - x0) / 2.0; b = (y1 - y0) / 2.0;
    if (b < 0.5) { line(plot, x0, y0, x1, y0, s, c, 0); return; }
    for (y = y0; y <= y1; y++) {
        double t = (y - cyd) / (b + 0.5), k = 1 - t * t, hw;
        int l, r, x;
        if (k < 0) k = 0;
        hw = (a + 0.5) * sqrt(k);
        l = (int)(cxd - hw + 0.5); r = (int)(cxd + hw + 0.5);
        if (l < x0) l = x0;
        if (r > x1) r = x1;
        if (filled) { for (x = l; x <= r; x++) plot(x, y, c); continue; }
        if (first) {
            for (x = l; x <= r; x++) stamp(plot, x, y, s, c, 0);
            first = 0;
        } else {
            int a1 = l < prev_l ? l : prev_l, b1 = l < prev_l ? prev_l : l;
            int a2 = r < prev_r ? r : prev_r, b2 = r < prev_r ? prev_r : r;
            for (x = a1; x <= b1; x++) stamp(plot, x, y, s, c, 0);
            for (x = a2; x <= b2; x++) stamp(plot, x, y, s, c, 0);
        }
        if (y == y1) for (x = l; x <= r; x++) stamp(plot, x, y, s, c, 0);
        prev_l = l; prev_r = r;
    }
}

/* the fill: one span of a color at a time, the spans above and below
 * it seeded onto a stack */
static int fstack[FILL_STACK];
static void flood(int x, int y, unsigned c)
{
    unsigned short old, nw = to565(c);
    int sp = 0;
    if (x < 0 || x >= cw || y < 0 || y >= ch) return;
    old = canvas[y * cw + x];
    if (old == nw) return;
    fstack[sp++] = y << 16 | x;
    while (sp) {
        int v = fstack[--sp], sx = v & 0xFFFF, sy = v >> 16, l = sx, r = sx, i, d;
        unsigned short *row = canvas + sy * cw;
        if (row[sx] != old) continue;
        while (l > 0 && row[l - 1] == old) l--;
        while (r < cw - 1 && row[r + 1] == old) r++;
        for (i = l; i <= r; i++) row[i] = nw;
        for (d = -1; d <= 1; d += 2) {
            int ny = sy + d, in = 0;
            unsigned short *nr;
            if (ny < 0 || ny >= ch) continue;
            nr = canvas + ny * cw;
            for (i = l; i <= r; i++) {
                if (nr[i] == old) {
                    if (!in && sp < FILL_STACK) fstack[sp++] = ny << 16 | i;
                    in = 1;
                } else in = 0;
            }
        }
    }
}

/* ============================================================
 * undo: the picture as runs (count, color) - a drawing's mostly runs
 * ============================================================ */
static void snap_free(struct snap *s) { free(s->runs); s->runs = 0; }
static int snap_take(struct snap *s)
{
    int i, n = 0, total = cw * ch;
    unsigned short *r;
    for (i = 0; i < total; ) {                   /* how many runs */
        int j = i + 1;
        while (j < total && j - i < 65535 && canvas[j] == canvas[i]) j++;
        n++; i = j;
    }
    r = malloc(n * 4);
    if (!r) return 0;
    for (i = 0, n = 0; i < total; ) {
        int j = i + 1;
        while (j < total && j - i < 65535 && canvas[j] == canvas[i]) j++;
        r[n * 2] = (unsigned short)(j - i); r[n * 2 + 1] = canvas[i];
        n++; i = j;
    }
    s->runs = r; s->n = n; s->w = cw; s->h = ch;
    return 1;
}
static void snap_put(struct snap *s)
{
    int i, k, p = 0;
    cw = s->w; ch = s->h;
    for (i = 0; i < s->n; i++)
        for (k = 0; k < s->runs[i * 2]; k++) canvas[p++] = s->runs[i * 2 + 1];
}
static void drop_oldest(struct snap *list, int *n)
{
    int i;
    if (!*n) return;
    snap_free(&list[0]);
    for (i = 1; i < *n; i++) list[i - 1] = list[i];
    (*n)--;
}
static int push_snap(struct snap *list, int *n)
{
    if (*n == UNDO_MAX) drop_oldest(list, n);
    while (!snap_take(&list[*n])) {              /* no room: fewer steps back */
        if (!nundo && !nredo) return 0;
        if (list == undo ? nredo : nundo) drop_oldest(list == undo ? redo : undo, list == undo ? &nredo : &nundo);
        else drop_oldest(list, n);
    }
    (*n)++;
    return 1;
}
static void clear_redo(void) { while (nredo) snap_free(&redo[--nredo]); }
static void before_change(void)                 /* the picture, kept */
{
    clear_redo();
    push_snap(undo, &nundo);
    dirty = 1;
}
static void clamp_view(void);
static void undo_redo(int again)
{
    struct snap *from = again ? redo : undo, *to = again ? undo : redo;
    int *nf = again ? &nredo : &nundo, *nt = again ? &nundo : &nredo;
    if (!*nf) { say(again ? "Nothing to redo." : "Nothing to undo."); return; }
    push_snap(to, nt);
    (*nf)--;
    snap_put(&from[*nf]);
    snap_free(&from[*nf]);
    dirty = 1;
    clamp_view();
    say(again ? "Redone." : "Undone.");
}

/* ============================================================
 * the picture: new, resize, .BMP in and out
 * ============================================================ */
static void blank(int w, int h)
{
    int i;
    cw = w; ch = h;
    for (i = 0; i < cw * ch; i++) canvas[i] = 0xFFFF;
    vx = vy = 0;
}
static void resize(int w, int h)
{
    static unsigned short row[CMAX_W];
    int x, y, ow = cw, oh = ch;
    unsigned short b = to565(bg);
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    if (w > CMAX_W) w = CMAX_W;
    if (h > CMAX_H) h = CMAX_H;
    if (w == cw && h == ch) return;
    before_change();
    if (w > ow) {                                /* wider: from the bottom up */
        for (y = (h < oh ? h : oh) - 1; y >= 0; y--) {
            memcpy(row, canvas + y * ow, ow * 2);
            for (x = 0; x < w; x++) canvas[y * w + x] = x < ow ? row[x] : b;
        }
    } else {                                     /* narrower: top down */
        for (y = 0; y < (h < oh ? h : oh); y++) {
            memcpy(row, canvas + y * ow, w * 2);
            memcpy(canvas + y * w, row, w * 2);
        }
    }
    for (y = oh; y < h; y++) for (x = 0; x < w; x++) canvas[y * w + x] = b;
    cw = w; ch = h;
    clamp_view();
}

static const char *base_name(const char *p)
{
    const char *b = p;
    while (*p) { if (*p == '/') b = p + 1; p++; }
    return b;
}
static void set_path(const char *p)
{
    copy(path, p, PATH_MAX);
    copy(name, base_name(p), sizeof name);
}
static unsigned rd32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (unsigned)p[3] << 24; }
static void wr32(unsigned char *p, unsigned v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

static int load_bmp(const char *p)
{
    static unsigned char hdr[54 + 1024], rowbuf[CMAX_W * 4 + 8];
    int fd = open(p, O_READ), w, h, bpp, top = 0, stride, y, x, n, off, colors, sw, sh;
    unsigned pal[256];
    if (fd < 0) { say("Can't open it."); return 0; }
    n = read(fd, hdr, sizeof hdr);
    if (n < 54 || hdr[0] != 'B' || hdr[1] != 'M' || rd32(hdr + 30) != 0) { close(fd); say("Not a picture Paint can open (a plain .BMP)."); return 0; }
    off = rd32(hdr + 10); w = rd32(hdr + 18); h = rd32(hdr + 22); bpp = hdr[28] | hdr[29] << 8;
    if (h < 0) { h = -h; top = 1; }
    if (w <= 0 || h <= 0 || (bpp != 8 && bpp != 24 && bpp != 32)) { close(fd); say("Paint opens 8-, 24- and 32-bit .BMPs."); return 0; }
    if (bpp == 8) {
        int po = 14 + rd32(hdr + 14), i;
        colors = rd32(hdr + 46);
        if (!colors || colors > 256) colors = 256;
        for (i = 0; i < 256; i++) pal[i] = 0;
        for (i = 0; i < colors && po + i * 4 + 3 < n; i++)
            pal[i] = RGB(hdr[po + i * 4 + 2], hdr[po + i * 4 + 1], hdr[po + i * 4]);
    }
    stride = (w * (bpp / 8) + 3) & ~3;
    sw = w > CMAX_W ? CMAX_W : w; sh = h > CMAX_H ? CMAX_H : h;
    blank(sw, sh);
    for (y = 0; y < h; y++) {
        int row = top ? y : h - 1 - y;
        seek(fd, off + y * stride);
        if (read(fd, rowbuf, stride > (int)sizeof rowbuf ? (int)sizeof rowbuf : stride) <= 0) break;
        if (row >= sh) continue;
        for (x = 0; x < sw; x++) {
            unsigned c;
            if (bpp == 8) c = pal[rowbuf[x]];
            else { const unsigned char *q = rowbuf + x * (bpp / 8); c = RGB(q[2], q[1], q[0]); }
            canvas[row * cw + x] = to565(c);
        }
    }
    close(fd);
    set_path(p);
    dirty = 0;
    while (nundo) snap_free(&undo[--nundo]);
    clear_redo();
    say(w > CMAX_W || h > CMAX_H ? "Opened - cut to 800x600, Paint's most." : "Opened.");
    return 1;
}
static int save_bmp(const char *p)
{
    static unsigned char hdr[54], rowbuf[CMAX_W * 3 + 4];
    int fd, y, x, stride = (cw * 3 + 3) & ~3;
    memset(hdr, 0, sizeof hdr);
    hdr[0] = 'B'; hdr[1] = 'M';
    wr32(hdr + 2, 54 + stride * ch);
    wr32(hdr + 10, 54);
    wr32(hdr + 14, 40);
    wr32(hdr + 18, cw); wr32(hdr + 22, ch);
    hdr[26] = 1; hdr[28] = 24;
    wr32(hdr + 34, stride * ch);
    wr32(hdr + 38, 2835); wr32(hdr + 42, 2835);
    fd = open(p, O_WRITE);
    if (fd < 0) { say("Can't save there (read-only, or no room?)."); return 0; }
    fwrite(fd, hdr, 54);
    memset(rowbuf, 0, sizeof rowbuf);
    for (y = ch - 1; y >= 0; y--) {
        for (x = 0; x < cw; x++) {
            unsigned c = from565(canvas[y * cw + x]);
            rowbuf[x * 3] = c; rowbuf[x * 3 + 1] = c >> 8; rowbuf[x * 3 + 2] = c >> 16;
        }
        if (fwrite(fd, rowbuf, stride) != stride) { close(fd); say("The disk is full - not saved."); return 0; }
    }
    close(fd);
    set_path(p);
    dirty = 0;
    {
        char s[120] = "Saved: ";
        append(s, name, sizeof s);
        notify(s);
        say(s);
    }
    return 1;
}

/* a PNG: its pixels straight onto the canvas (png.h's sink) */
static void png_to_canvas(int x, int y, int r, int g, int b) { canvas[y * cw + x] = to565(RGB(r, g, b)); }
static int load_png(const char *p)
{
    int fd = open(p, O_READ), n, w, h;
    unsigned char *buf;
    if (fd < 0) { say("Can't open it."); return 0; }
    n = fsize(fd);
    buf = malloc(n + 4);
    while (!buf && (nundo || nredo)) {                 /* no room: fewer steps back */
        if (nredo) drop_oldest(redo, &nredo); else drop_oldest(undo, &nundo);
        buf = malloc(n + 4);
    }
    if (!buf) { close(fd); say("Too big to open."); return 0; }
    n = read(fd, buf, n);
    close(fd);
    if (!png_size(buf, n, CMAX_W, CMAX_H, &w, &h)) { free(buf); say("Not a PNG Paint can open."); return 0; }
    blank(w, h);
    png_sink = png_to_canvas;
    n = png_to_bmp(buf, n, 0, 0, CMAX_W, CMAX_H);
    png_sink = 0;
    free(buf);
    if (n < 0) { say("That PNG couldn't be read (damaged?)."); return 0; }
    set_path(p);
    dirty = 0;
    while (nundo) snap_free(&undo[--nundo]);
    clear_redo();
    say("Opened.");
    return 1;
}
static int load_picture(const char *p)
{
    unsigned char sig[8];
    int fd = open(p, O_READ), n = 0;
    if (fd >= 0) { n = read(fd, sig, 8); close(fd); }
    if (n == 8 && sig[0] == 137 && sig[1] == 'P' && sig[2] == 'N' && sig[3] == 'G') return load_png(p);
    return load_bmp(p);
}

static void be32w(unsigned char *p, unsigned v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
/* a chunk: its length, type, data, CRC */
static int png_chunk(int fd, const char *type, const unsigned char *d, int n)
{
    unsigned char h[8], t[4];
    unsigned c = 0xFFFFFFFF;
    int i;
    be32w(h, n);
    memcpy(h + 4, type, 4);
    for (i = 4; i < 8; i++) c = crc_table[(c ^ h[i]) & 0xFF] ^ (c >> 8);
    for (i = 0; i < n; i++) c = crc_table[(c ^ d[i]) & 0xFF] ^ (c >> 8);
    be32w(t, c ^ 0xFFFFFFFF);
    if (fwrite(fd, h, 8) != 8) return 0;
    if (n && fwrite(fd, d, n) != n) return 0;
    return fwrite(fd, t, 4) == 4;
}
/* the canvas as a PNG: RGB, 8 bits; the rows Paeth-filtered, compressed
 * 16 at a time, each piece its own IDAT */
#define PNG_ROWS 16
static int save_png(const char *p)
{
    static const unsigned char sig[8] = { 137, 80, 78, 71, 13, 10, 26, 10 };
    static unsigned char raw[PNG_ROWS * (CMAX_W * 3 + 1)], zbuf[PNG_ROWS * (CMAX_W * 3 + 1) + 4096];
    static unsigned char row[CMAX_W * 3], prev[CMAX_W * 3];
    unsigned char ihdr[13];
    unsigned a1 = 1, a2 = 0;
    int fd, y, x, ok = 1, first = 1;
    crc_init();
    while (deflate_start(zbuf, sizeof zbuf) && (nundo || nredo)) {   /* its tables: room made */
        if (nredo) drop_oldest(redo, &nredo); else drop_oldest(undo, &nundo);
    }
    if (!df_head) { say("Not enough memory to save a PNG - try .BMP."); return 0; }
    fd = open(p, O_WRITE);
    if (fd < 0) { deflate_free(); say("Can't save there (read-only, or no room?)."); return 0; }
    be32w(ihdr, cw); be32w(ihdr + 4, ch);
    ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = ihdr[11] = ihdr[12] = 0;
    fwrite(fd, sig, 8);
    ok = png_chunk(fd, "IHDR", ihdr, 13);
    memset(prev, 0, sizeof prev);
    for (y = 0; y < ch && ok; ) {
        int n = 0, rows, got, i;
        for (rows = 0; rows < PNG_ROWS && y < ch; rows++, y++) {
            for (x = 0; x < cw; x++) {
                unsigned c = from565(canvas[y * cw + x]);
                row[x * 3] = c >> 16; row[x * 3 + 1] = c >> 8; row[x * 3 + 2] = c;
            }
            raw[n++] = 4;                                  /* Paeth */
            for (i = 0; i < cw * 3; i++) {
                int a = i >= 3 ? row[i - 3] : 0, b = prev[i], c = i >= 3 ? prev[i - 3] : 0;
                int pp = a + b - c, pa = pp > a ? pp - a : a - pp, pb = pp > b ? pp - b : b - pp, pc = pp > c ? pp - c : c - pp;
                raw[n++] = row[i] - (pa <= pb && pa <= pc ? a : pb <= pc ? b : c);
            }
            memcpy(prev, row, cw * 3);
        }
        for (i = 0; i < n; i++) { a1 = (a1 + raw[i]) % 65521; a2 = (a2 + a1) % 65521; }
        got = deflate_more(raw, n, y >= ch);
        if (got < 0) { ok = 0; break; }
        if (first) {                                        /* the zlib header, first */
            unsigned char zh[2] = { 0x78, 0x01 };
            unsigned char *both = malloc(got + 2);
            if (!both) { ok = 0; break; }
            memcpy(both, zh, 2); memcpy(both + 2, zbuf, got);
            ok = png_chunk(fd, "IDAT", both, got + 2);
            free(both);
            first = 0;
        } else if (got) ok = png_chunk(fd, "IDAT", zbuf, got);
        deflate_taken();
    }
    if (ok) {                                               /* the checksum, the end */
        unsigned char ad[4];
        be32w(ad, a2 << 16 | a1);
        ok = png_chunk(fd, "IDAT", ad, 4) && png_chunk(fd, "IEND", 0, 0);
    }
    close(fd);
    deflate_free();
    if (!ok) { say("The disk is full - not saved."); return 0; }
    set_path(p);
    dirty = 0;
    {
        char s[120] = "Saved: ";
        append(s, name, sizeof s);
        notify(s);
        say(s);
    }
    return 1;
}
static int save_picture(const char *p)
{
    return ends_ci(p, ".PNG") ? save_png(p) : save_bmp(p);
}

/* ============================================================
 * the layout
 * ============================================================ */
#define TB_X 8                                   /* the tools, 34 apart */
#define TB_Y 6
#define TB_S 32
#define SZ_X (TB_X + NTOOLS * 34 + 12)           /* the sizes */
#define CMD_X (SZ_X + 4 * 28 + 14)               /* New, Open, Save, Undo, Redo */
#define CMD_W 58
static const char *cmd_label[5] = { "New", "Open", "Save", "Undo", "Redo" };
#define SW_X 8                                   /* the two colors */
#define PC_X 64                                  /* the palette: 14 x 2 */
#define PC_S 20

/* the buttons: 0-9 tools, 10-13 sizes, 20-24 commands, 30-32 a
 * dialog's, 40+ the palette; -1 none */
static int button_at(int x, int y)
{
    if (dlg) {
        if (dlg == DLG_ASK) {
            int bx = 200, by = 220;
            if (y >= by + 90 && y < by + 116) {
                if (x >= bx + 16 && x < bx + 126) return 30;
                if (x >= bx + 136 && x < bx + 246) return 31;
                if (x >= bx + 256 && x < bx + 366) return 32;
            }
            return -1;
        }
        if (y >= 90 + 420 - 40 && y < 90 + 420 - 12) {
            if (x >= 140 + 520 - 220 && x < 140 + 520 - 120) return 30;
            if (x >= 140 + 520 - 112 && x < 140 + 520 - 12) return 32;
        }
        return -1;
    }
    if (y >= TB_Y && y < TB_Y + TB_S) {
        if (x >= TB_X && x < TB_X + NTOOLS * 34 && (x - TB_X) % 34 < TB_S) return (x - TB_X) / 34;
        if (x >= SZ_X && x < SZ_X + 4 * 28 && (x - SZ_X) % 28 < 26) return 10 + (x - SZ_X) / 28;
        if (x >= CMD_X && x < CMD_X + 5 * (CMD_W + 4) && (x - CMD_X) % (CMD_W + 4) < CMD_W) return 20 + (x - CMD_X) / (CMD_W + 4);
    }
    if (y >= PAL_Y + 3 && y < PAL_Y + 3 + 2 * PC_S && x >= PC_X && x < PC_X + 14 * PC_S)
        return 40 + ((y - PAL_Y - 3) / PC_S) * 14 + (x - PC_X) / PC_S;
    return -1;
}

/* the tools' pictures, drawn with the shapes themselves */
static int ico_x, ico_y;
static void iplot(int x, int y, unsigned c) { fpix(ico_x + x, ico_y + y, c); }
static void draw_icon(int t, int x, int y)
{
    unsigned k = RGB(48, 54, 66);
    ico_x = x; ico_y = y;
    switch (t) {
    case T_PENCIL:
        line(iplot, 5, 18, 17, 6, 3, RGB(242, 194, 48), 0);
        line(iplot, 16, 5, 19, 8, 2, RGB(240, 140, 160), 0);
        line(iplot, 3, 20, 5, 18, 2, k, 0);
        break;
    case T_BRUSH:
        line(iplot, 10, 13, 19, 4, 2, RGB(154, 106, 58), 0);
        stamp(iplot, 7, 16, 5, k, 0);
        line(iplot, 4, 20, 6, 18, 2, k, 0);
        break;
    case T_ERASER:
        rect(iplot, 4, 8, 19, 16, 1, RGB(240, 140, 160), 1);
        rect(iplot, 4, 8, 9, 16, 1, RGB(255, 255, 255), 1);
        rect(iplot, 4, 8, 19, 16, 1, k, 0);
        break;
    case T_LINE: line(iplot, 4, 19, 19, 4, 2, k, 0); break;
    case T_RECT: rect(iplot, 3, 6, 20, 17, 2, k, 0); break;
    case T_BOX:
        rect(iplot, 3, 6, 20, 17, 1, RGB(47, 111, 219), 1);
        rect(iplot, 3, 6, 20, 17, 1, k, 0);
        break;
    case T_OVAL: oval(iplot, 2, 5, 21, 18, 2, k, 0); break;
    case T_DISC:
        oval(iplot, 2, 5, 21, 18, 1, RGB(47, 111, 219), 1);
        oval(iplot, 2, 5, 21, 18, 1, k, 0);
        break;
    case T_FILL:
        line(iplot, 4, 11, 11, 4, 1, k, 0); line(iplot, 11, 4, 18, 11, 1, k, 0);
        line(iplot, 18, 11, 11, 18, 1, k, 0); line(iplot, 11, 18, 4, 11, 1, k, 0);
        stamp(iplot, 19, 17, 5, RGB(47, 111, 219), 0);
        line(iplot, 19, 12, 19, 15, 2, RGB(47, 111, 219), 0);
        break;
    case T_PICK:
        line(iplot, 4, 19, 13, 10, 2, RGB(150, 156, 168), 0);
        stamp(iplot, 16, 7, 7, k, 0);
        break;
    }
}

static void draw_toolbar(void)
{
    int i;
    fill(0, 0, W, TOOL_H, C_BAR);
    fill(0, TOOL_H - 1, W, 1, C_BAR_LO);
    for (i = 0; i < NTOOLS; i++) {
        int x = TB_X + i * 34;
        fill(x, TB_Y, TB_S, TB_S, C_BAR_LO);
        fill(x + 1, TB_Y + 1, TB_S - 2, TB_S - 2, i == tool ? C_ON : hover == i ? C_HOVER : C_BTN);
        draw_icon(i, x + 4, TB_Y + 4);
    }
    for (i = 0; i < 4; i++) {
        int x = SZ_X + i * 28, s = sizes[i] > 9 ? 9 : sizes[i];
        fill(x, TB_Y, 26, TB_S, C_BAR_LO);
        fill(x + 1, TB_Y + 1, 24, TB_S - 2, i == size_i ? C_ON : hover == 10 + i ? C_HOVER : C_BTN);
        ico_x = x + 13; ico_y = TB_Y + 16;
        stamp(iplot, 0, 0, s + 1, C_TEXT, 0);
    }
    for (i = 0; i < 5; i++)
        button(CMD_X + i * (CMD_W + 4), TB_Y, CMD_W, TB_S, cmd_label[i], hover == 20 + i);
}

static void draw_area(void)
{
    int x, y, sx0 = cx0(), sy0 = cy0();
    fill(0, AREA_Y, W, AREA_H, C_AREA);
    for (y = 0; y < ch; y++) {
        int sy = sy0 + y, xa, xb;
        unsigned *out;
        const unsigned short *in;
        if (sy < AREA_Y) continue;
        if (sy >= AREA_Y + AREA_H) break;
        xa = sx0 < 0 ? -sx0 : 0;
        xb = cw;
        if (sx0 + xb > W) xb = W - sx0;
        out = frame + sy * W + sx0;
        in = canvas + y * cw;
        for (x = xa; x < xb; x++) out[x] = from565(in[x]);
    }
    /* the corner that resizes it */
    x = sx0 + cw; y = sy0 + ch;
    if (y < AREA_Y + AREA_H && x < W) fill(x, y, 5, 5, C_ACCENT);
    if (sy0 + ch < AREA_Y + AREA_H) fill(sx0 + 3, sy0 + ch, cw, 2, RGB(120, 126, 140));
    if (sx0 + cw < W) fill(sx0 + cw, sy0 + 3, 2, ch - 3 < AREA_H ? ch - 3 : AREA_H, RGB(120, 126, 140));
}

static void draw_palette(void)
{
    int i;
    fill(0, PAL_Y, W, PAL_H, C_BAR);
    fill(0, PAL_Y, W, 1, C_BAR_LO);
    /* the two colors: the second behind the first */
    fill(SW_X + 18, PAL_Y + 17, 26, 24, C_BAR_LO);
    fill(SW_X + 19, PAL_Y + 18, 24, 22, bg);
    fill(SW_X, PAL_Y + 5, 26, 24, C_BAR_LO);
    fill(SW_X + 1, PAL_Y + 6, 24, 22, fg);
    for (i = 0; i < 28; i++) {
        int x = PC_X + (i % 14) * PC_S, y = PAL_Y + 3 + (i / 14) * PC_S;
        fill(x, y, PC_S - 2, PC_S - 2, hover == 40 + i ? C_ACCENT : C_BAR_LO);
        fill(x + 1, y + 1, PC_S - 4, PC_S - 4, palette[i]);
    }
    text(PC_X + 14 * PC_S + 16, PAL_Y + 6, "Left button: the first color,", C_GRAY, 400);
    text(PC_X + 14 * PC_S + 16, PAL_Y + 24, "right button: the second.", C_GRAY, 400);
}

static int mouse_cx = -1, mouse_cy = -1;
static void draw_status(void)
{
    char s[120];
    fill(0, H - STATUS_H, W, STATUS_H, C_BAR);
    fill(0, H - STATUS_H, W, 1, C_BAR_LO);
    s[0] = 0;
    append(s, name, sizeof s);
    if (dirty) append(s, " *", sizeof s);
    append(s, "  ", sizeof s);
    append_num(s, cw, sizeof s); append(s, " x ", sizeof s); append_num(s, ch, sizeof s);
    if (mouse_cx >= 0) {
        append(s, "   ", sizeof s);
        append_num(s, mouse_cx, sizeof s); append(s, ", ", sizeof s); append_num(s, mouse_cy, sizeof s);
    }
    append(s, "   ", sizeof s);
    append(s, tool_name[tool], sizeof s);
    text(8, H - STATUS_H + 3, s, C_TEXT, 440);
    text(W - 8 - 8 * (int)strlen(status), H - STATUS_H + 3, status, C_ACCENT, W - 460);
}

#define DX 140
#define DY 90
#define DW 520
#define DH 420
#define LIST_Y (DY + 64)
#define LIST_H 272
#define LIST_ROWS (LIST_H / 18)

static void draw_field(int x, int y, int w, const char *label, const char *val, int chosen)
{
    int lw = 8 * strlen(label) + 8, vl = strlen(val), show = (w - lw - 8) / 8;
    text(x, y + 4, label, C_TEXT, 200);
    fill(x + lw, y, w - lw, 24, C_ACCENT);
    fill(x + lw + 1, y + 1, w - lw - 2, 22, C_BG);
    if (chosen && vl) fill(x + lw + 3, y + 4, 8 * (vl > show ? show : vl) + 2, 16, C_SEL);
    text(x + lw + 4, y + 4, vl > show ? val + vl - show : val, C_TEXT, w - lw - 8);
    fill(x + lw + 4 + 8 * (vl > show ? show : vl), y + 4, 2, 16, C_TEXT);
}
static void draw_dialog(void)
{
    int i;
    if (!dlg) return;
    if (dlg == DLG_ASK) {
        int x = 200, y = 220, w = 400, h = 130;
        char q[80];
        fill(x + 4, y + 4, w, h, RGB(90, 96, 110));
        fill(x, y, w, h, C_BAR_LO);
        fill(x + 1, y + 1, w - 2, h - 2, C_BTN);
        fill(x + 1, y + 1, w - 2, 24, C_ACCENT);
        text(x + 10, y + 5, "Paint", RGB(255, 255, 255), 200);
        copy(q, "Save the changes to ", sizeof q);
        append(q, name, sizeof q);
        append(q, "?", sizeof q);
        text(x + 16, y + 44, q, C_TEXT, w - 32);
        button(x + 16, y + 90, 110, 26, "Save", hover == 30);
        button(x + 136, y + 90, 110, 26, "Don't save", hover == 31);
        button(x + 256, y + 90, 110, 26, "Cancel", hover == 32);
        return;
    }
    fill(DX + 4, DY + 4, DW, DH, RGB(90, 96, 110));
    fill(DX, DY, DW, DH, C_BAR_LO);
    fill(DX + 1, DY + 1, DW - 2, DH - 2, C_BTN);
    fill(DX + 1, DY + 1, DW - 2, 24, C_ACCENT);
    text(DX + 10, DY + 5, dlg == DLG_OPEN ? "Open a picture" : "Save as", RGB(255, 255, 255), 200);
    text(DX + 12, DY + 36, "Folder:", C_GRAY, 80);
    text(DX + 76, DY + 36, dlg_dir, C_TEXT, DW - 90);
    fill(DX + 12, LIST_Y, DW - 24, LIST_H, C_BAR_LO);
    fill(DX + 13, LIST_Y + 1, DW - 26, LIST_H - 2, C_BG);
    for (i = 0; i < LIST_ROWS; i++) {
        int k = dlg_scroll + i, y = LIST_Y + 2 + i * 18;
        char sz[24];
        if (k >= ndents) break;
        if (k == dlg_sel) fill(DX + 14, y, DW - 28, 18, C_SEL);
        if (dents[k].type == LX_DIR) {
            fill(DX + 20, y + 5, 14, 9, RGB(236, 190, 40));
            fill(DX + 20, y + 3, 6, 3, RGB(236, 190, 40));
        } else {
            fill(DX + 21, y + 3, 13, 12, C_GRAY);
            fill(DX + 22, y + 4, 11, 10, RGB(120, 190, 240));
            fill(DX + 22, y + 10, 11, 4, RGB(90, 170, 90));
        }
        text(DX + 42, y + 1, dents[k].name, C_TEXT, 200);
        sz[0] = 0;
        if (dents[k].type == LX_DIR) append(sz, !strcmp(dents[k].name, "..") ? "" : "folder", sizeof sz);
        else { append_num(sz, dents[k].size, sizeof sz); append(sz, " bytes", sizeof sz); }
        text(DX + DW - 30 - 8 * (int)strlen(sz), y + 1, sz, C_GRAY, 200);
    }
    if (ndents > LIST_ROWS) {
        int tl = LIST_H * LIST_ROWS / ndents, ty = LIST_Y + (LIST_H - tl) * dlg_scroll / (ndents - LIST_ROWS);
        fill(DX + DW - 22, ty, 8, tl, C_BAR_LO);
    }
    draw_field(DX + 12, DY + DH - 76, DW - 24, "Name:", dlg_name, dlg_fresh);
    button(DX + DW - 220, DY + DH - 40, 100, 28, dlg == DLG_OPEN ? "Open" : "Save", hover == 30);
    button(DX + DW - 112, DY + DH - 40, 100, 28, "Cancel", hover == 32);
}

/* a shape being dragged: drawn over the picture, not into it yet */
static int shaping, sx_a, sy_a, sx_b, sy_b, shape_btn;
static int sizing, size_w, size_h;
static void constrain(int *x, int *y)          /* Shift: square, 45 degrees */
{
    int dx = *x - sx_a, dy = *y - sy_a;
    if (!shift()) return;
    if (tool == T_LINE) {
        if (iabs(dx) > 2 * iabs(dy)) dy = 0;
        else if (iabs(dy) > 2 * iabs(dx)) dx = 0;
        else { int d = iabs(dx) > iabs(dy) ? iabs(dx) : iabs(dy); dx = dx < 0 ? -d : d; dy = dy < 0 ? -d : d; }
    } else {
        int d = iabs(dx) > iabs(dy) ? iabs(dx) : iabs(dy);
        dx = dx < 0 ? -d : d; dy = dy < 0 ? -d : d;
    }
    *x = sx_a + dx; *y = sy_a + dy;
}
static void draw_shape(plot_fn plot)
{
    unsigned c = shape_btn == 2 ? bg : fg;
    int s = sizes[size_i];
    switch (tool) {
    case T_LINE: line(plot, sx_a, sy_a, sx_b, sy_b, s, c, 0); break;
    case T_RECT: rect(plot, sx_a, sy_a, sx_b, sy_b, s, c, 0); break;
    case T_BOX:  rect(plot, sx_a, sy_a, sx_b, sy_b, s, c, 1); break;
    case T_OVAL: oval(plot, sx_a, sy_a, sx_b, sy_b, s, c, 0); break;
    case T_DISC: oval(plot, sx_a, sy_a, sx_b, sy_b, s, c, 1); break;
    }
}

static void redraw(void)
{
    draw_toolbar();
    draw_area();
    if (shaping) draw_shape(pplot);
    if (sizing) {                                /* the new size's outline */
        int x0 = cx0(), y0 = cy0(), i;
        for (i = 0; i < size_w; i += 2) { fpix(x0 + i, y0 + size_h, C_TEXT); fpix(x0 + i, y0 - 1, C_TEXT); }
        for (i = 0; i < size_h; i += 2) { fpix(x0 + size_w, y0 + i, C_TEXT); fpix(x0 - 1, y0 + i, C_TEXT); }
    }
    draw_palette();
    draw_status();
    draw_dialog();
    gfx_blit(frame);
}

static void clamp_view(void)
{
    int mx = cw + 2 * MARGIN - W, my = ch + 2 * MARGIN - AREA_H;
    if (vx > mx) vx = mx;
    if (vy > my) vy = my;
    if (vx < 0) vx = 0;
    if (vy < 0) vy = 0;
}

/* ============================================================
 * the Open / Save as dialog
 * ============================================================ */
static void list_dir(void)
{
    int i, j;
    struct lx_dirent e;
    ndents = 0;
    if (strcmp(dlg_dir, "/")) { memset(&dents[0], 0, sizeof dents[0]); copy(dents[0].name, "..", 16); dents[0].type = LX_DIR; ndents = 1; }
    for (i = 0; ndents < 200 && readdir(dlg_dir, i, &e) == 0; i++)
        if (e.type == LX_DIR || ends_ci(e.name, ".BMP") || ends_ci(e.name, ".PNG")) dents[ndents++] = e;
    for (i = 1; i < ndents; i++) {               /* folders first, by name */
        struct lx_dirent t = dents[i];
        int tk = t.type == LX_DIR ? 0 : 1;
        for (j = i; j > 0 && strcmp(dents[j - 1].name, "..") != 0; j--) {
            int pk = dents[j - 1].type == LX_DIR ? 0 : 1;
            if (pk < tk || (pk == tk && strcmp(dents[j - 1].name, t.name) <= 0)) break;
            dents[j] = dents[j - 1];
        }
        dents[j] = t;
    }
    dlg_scroll = 0;
    dlg_sel = -1;
}
static void open_dialog(int kind)
{
    dlg = kind;
    copy(dlg_dir, last_dir, PATH_MAX);
    dlg_name[0] = 0;
    dlg_fresh = 0;
    if (kind == DLG_SAVE) {
        if (path[0]) {
            int l = base_name(path) - path - 1;
            if (l < 1) l = 1;
            copy(dlg_dir, path, l + 1);
        }
        copy(dlg_name, name, FIELD_MAX);
        dlg_fresh = 1;
    }
    list_dir();
}
static void join(char *out, const char *dir, const char *nm)
{
    copy(out, dir, PATH_MAX);
    if (strcmp(dir, "/")) append(out, "/", PATH_MAX);
    append(out, nm, PATH_MAX);
}
static void enter_dir(const char *nm)
{
    if (!strcmp(nm, "..")) {
        int l = strlen(dlg_dir);
        while (l > 1 && dlg_dir[l - 1] != '/') l--;
        if (l > 1) l--;
        dlg_dir[l] = 0;
    } else {
        char p[PATH_MAX];
        join(p, dlg_dir, nm);
        copy(dlg_dir, p, PATH_MAX);
    }
    list_dir();
}
static void new_picture(void)
{
    blank(640, 400);
    path[0] = 0;
    copy(name, "UNTITLED.BMP", sizeof name);
    dirty = 0;
    while (nundo) snap_free(&undo[--nundo]);
    clear_redo();
    say("A new picture.");
}
static void then_do(int what)                  /* after the changes are dealt with */
{
    if (what == 1) new_picture();
    else if (what == 2) open_dialog(DLG_OPEN);
    else if (what == 3) quitting = 1;
}
static void ask_first(int what)
{
    if (dirty) { dlg = DLG_ASK; ask_then = what; return; }
    then_do(what);
}
static void save(int as)
{
    if (as || !path[0]) { open_dialog(DLG_SAVE); return; }
    save_picture(path);
}
static void dialog_ok(void)
{
    char p[PATH_MAX];
    int i;
    if (dlg == DLG_ASK) {                        /* Save */
        if (!path[0]) { open_dialog(DLG_SAVE); return; }
        dlg = 0;
        if (save_picture(path)) then_do(ask_then);
        ask_then = 0;
        return;
    }
    if (!dlg_name[0]) return;
    for (i = 0; i < ndents; i++)                 /* a folder's name: into it */
        if (dents[i].type == LX_DIR && !strcmp(dents[i].name, dlg_name)) { enter_dir(dlg_name); dlg_name[0] = 0; return; }
    if (dlg_name[0] == '/') copy(p, dlg_name, PATH_MAX);
    else join(p, dlg_dir, dlg_name);
    for (i = 0; p[i]; i++) p[i] = upper(p[i]);
    copy(last_dir, dlg_dir, PATH_MAX);
    if (dlg == DLG_OPEN) { dlg = 0; load_picture(p); clamp_view(); return; }
    if (!ends_ci(p, ".BMP") && !ends_ci(p, ".PNG") && strlen(p) + 4 < PATH_MAX) append(p, ".BMP", PATH_MAX);
    dlg = 0;
    if (save_picture(p) && ask_then) then_do(ask_then);
    ask_then = 0;
}
static void dialog_cancel(void) { dlg = 0; ask_then = 0; }

static void press(int b, int right)
{
    if (b >= 0 && b < NTOOLS) { tool = b; say(tool_name[b]); }
    else if (b >= 10 && b < 14) size_i = b - 10;
    else if (b == 20) ask_first(1);
    else if (b == 21) ask_first(2);
    else if (b == 22) save(0);
    else if (b == 23) undo_redo(0);
    else if (b == 24) undo_redo(1);
    else if (b == 30) dialog_ok();
    else if (b == 31) { int t = ask_then; dlg = 0; ask_then = 0; dirty = 0; then_do(t); }
    else if (b == 32) dialog_cancel();
    else if (b >= 40 && b < 68) { if (right) bg = palette[b - 40]; else fg = palette[b - 40]; }
}

static void key(int c, int sc)
{
    int ctrl = keydown(KEY_CTRL);
    if (dlg) {
        int l = strlen(dlg_name);
        if (c == 27) dialog_cancel();
        else if (c == 13) dialog_ok();
        else if (dlg == DLG_ASK) return;
        else if (c == 8) { if (dlg_fresh) dlg_name[0] = 0; else if (l) dlg_name[l - 1] = 0; dlg_fresh = 0; }
        else if (sc == 0x48 && dlg_sel > 0) { dlg_sel--; if (dents[dlg_sel].type != LX_DIR) copy(dlg_name, dents[dlg_sel].name, FIELD_MAX); }
        else if (sc == 0x50 && dlg_sel < ndents - 1) { dlg_sel++; if (dents[dlg_sel].type != LX_DIR) copy(dlg_name, dents[dlg_sel].name, FIELD_MAX); }
        else if (c >= 32 && c < 127) {
            if (dlg_fresh) { dlg_name[0] = 0; l = 0; dlg_fresh = 0; }
            if (l < FIELD_MAX - 1) { dlg_name[l] = upper(c); dlg_name[l + 1] = 0; }
        }
        if (dlg_sel >= 0) {
            if (dlg_sel < dlg_scroll) dlg_scroll = dlg_sel;
            if (dlg_sel >= dlg_scroll + LIST_ROWS) dlg_scroll = dlg_sel - LIST_ROWS + 1;
        }
        return;
    }
    if (c == 14) { ask_first(1); return; }                       /* Ctrl+N */
    if (c == 15) { ask_first(2); return; }                       /* Ctrl+O */
    if (c == 19) { save(shift()); return; }                      /* Ctrl+S */
    if (c == 26) { undo_redo(0); return; }                       /* Ctrl+Z */
    if (c == 25) { undo_redo(1); return; }                       /* Ctrl+Y */
    if (c == 17 || c == 27) { ask_first(3); return; }            /* Ctrl+Q, Esc */
    if (ctrl) return;
    if (sc == 0x53) {                                            /* Delete: clear */
        int i;
        before_change();
        for (i = 0; i < cw * ch; i++) canvas[i] = to565(bg);
        say("Cleared (Ctrl+Z brings it back).");
        return;
    }
    if (c == '[' || c == '-') { if (size_i > 0) size_i--; return; }
    if (c == ']' || c == '+' || c == '=') { if (size_i < 3) size_i++; return; }
    {
        int i;
        for (i = 0; i < NTOOLS; i++)
            if (upper(c) == tool_key[i]) { tool = i; say(tool_name[i]); }
    }
}

/* ============================================================
 * main: the keys and the mouse
 * ============================================================ */
int main(int argc, char **argv)
{
    int m[4], was = 0, drawing = 0, lx = 0, ly = 0;
    unsigned last_click = 0;
    if (gfx_mode_ex(W, H, 32) < 0) { puts("paint: needs 800x600 in 32 bits\n"); return 1; }
    font(glyphs);
    keymode(1);
    blank(640, 400);
    if (argc > 1) {
        char p[PATH_MAX];
        int i;
        copy(p, argv[1], PATH_MAX);
        for (i = 0; p[i]; i++) p[i] = upper(p[i]);
        if (!load_picture(p)) set_path(p);                       /* (a new one, by that name) */
        if (p[0] == '/') { int l = base_name(p) - p - 1; copy(last_dir, p, (l < 1 ? 1 : l) + 1); }
    } else say("Draw with the left or right button. Ctrl+S saves.");
    redraw();
    while (!quitting) {
        int k = pollkey(), changed = 0, over;
        while (k) {
            key(k & 0xFF, (k >> 8) & 0xFF);
            changed = 1;
            if (quitting) break;
            k = pollkey();
        }
        if (quitting) break;
        over = mouse(m);
        if (m[3]) {
            if (dlg == DLG_OPEN || dlg == DLG_SAVE) {
                dlg_scroll += m[3] * 3;
                if (dlg_scroll > ndents - LIST_ROWS) dlg_scroll = ndents - LIST_ROWS;
                if (dlg_scroll < 0) dlg_scroll = 0;
            } else if (shift()) vx += m[3] * 40;
            else vy += m[3] * 40;
            clamp_view();
            changed = 1;
        }
        if (over) {
            int btn = m[2] & 3, mx = m[0], my = m[1];
            int px = mx - cx0(), py = my - cy0();
            int hb = drawing || shaping || sizing ? -1 : button_at(mx, my);
            int in_area = my >= AREA_Y && my < AREA_Y + AREA_H;
            if (hb != hover) { hover = hb; changed = 1; }
            if (!dlg && in_area && px >= 0 && px < cw && py >= 0 && py < ch) {
                if (px != mouse_cx || py != mouse_cy) { mouse_cx = px; mouse_cy = py; changed = 1; }
            } else if (mouse_cx >= 0) { mouse_cx = -1; changed = 1; }
            if (btn && !was) {                                   /* pressed */
                unsigned now = millis();
                int dbl = now - last_click < 400;
                last_click = now;
                changed = 1;
                if (hb >= 0) press(hb, btn == 2);
                else if (dlg == DLG_OPEN || dlg == DLG_SAVE) {
                    if (mx >= DX + 12 && mx < DX + DW - 12 && my >= LIST_Y && my < LIST_Y + LIST_H) {
                        int k2 = dlg_scroll + (my - LIST_Y - 2) / 18;
                        if (k2 >= 0 && k2 < ndents) {
                            if (dbl && k2 == dlg_sel) {
                                if (dents[k2].type == LX_DIR) { enter_dir(dents[k2].name); dlg_name[0] = 0; }
                                else { copy(dlg_name, dents[k2].name, FIELD_MAX); dialog_ok(); }
                            } else {
                                dlg_sel = k2;
                                if (dents[k2].type != LX_DIR) { copy(dlg_name, dents[k2].name, FIELD_MAX); dlg_fresh = 0; }
                            }
                        }
                    }
                } else if (!dlg && in_area) {
                    if (px >= cw && px < cw + 6 && py >= ch && py < ch + 6) {
                        sizing = 1; size_w = cw; size_h = ch;
                    } else if (tool == T_FILL) {
                        if (px >= 0 && px < cw && py >= 0 && py < ch) {
                            before_change();
                            flood(px, py, btn == 2 ? bg : fg);
                        }
                    } else if (tool == T_PICK) {
                        if (px >= 0 && px < cw && py >= 0 && py < ch) {
                            unsigned c = from565(canvas[py * cw + px]);
                            if (btn == 2) bg = c; else fg = c;
                        }
                    } else if (tool >= T_LINE && tool <= T_DISC) {
                        shaping = 1; shape_btn = btn;
                        sx_a = sx_b = px; sy_a = sy_b = py;
                    } else {
                        before_change();
                        drawing = btn; lx = px; ly = py;
                        goto draw_now;
                    }
                }
            } else if (btn && drawing) {
draw_now:
                {
                    unsigned c = tool == T_ERASER ? bg : drawing == 2 ? bg : fg;
                    int s = tool == T_PENCIL ? 1 : tool == T_ERASER ? sizes[size_i] * 2 + 2 : sizes[size_i];
                    line(cplot, lx, ly, px, py, s, c, tool == T_ERASER);
                    lx = px; ly = py;
                    changed = 1;
                }
            } else if (btn && shaping) {
                int x = px, y = py;
                constrain(&x, &y);
                if (x != sx_b || y != sy_b) { sx_b = x; sy_b = y; changed = 1; }
            } else if (btn && sizing) {
                if (px != size_w || py != size_h) { size_w = px < 1 ? 1 : px > CMAX_W ? CMAX_W : px; size_h = py < 1 ? 1 : py > CMAX_H ? CMAX_H : py; changed = 1; }
            }
            if (!btn) {
                if (shaping) {                                   /* let go: into the picture */
                    before_change();
                    draw_shape(cplot);
                    shaping = 0;
                    changed = 1;
                }
                if (sizing) { sizing = 0; resize(size_w, size_h); changed = 1; }
                drawing = 0;
            }
            was = btn;
        } else {
            if (hover >= 0 || mouse_cx >= 0) { hover = -1; mouse_cx = -1; changed = 1; }
            was = 0;
            if (shaping) { before_change(); draw_shape(cplot); shaping = 0; changed = 1; }
            if (sizing) { sizing = 0; resize(size_w, size_h); changed = 1; }
            drawing = 0;
        }
        if (changed) redraw();
        sleep_ms(12);
    }
    gfx_mode(0);
    return 0;
}
