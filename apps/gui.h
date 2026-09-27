/* gui.h - a window's worth of drawing for LexOS programs in C.
 *
 * gui_open(w, h) makes the program's picture w x h, 32 bits a pixel
 * (on the desktop: a window that size), with a frame to draw into:
 * gui_fill / gui_box / gui_text... then gui_show() puts it on screen.
 * Text is the system's 8x16 font (code page 866), k times as big.
 *
 * gui_cfg_get / gui_cfg_set keep numbers between runs - a game's best
 * score, a player's volume - as "name=value" lines in
 * /SYSTEM/APPS.CFG, shared by every program. */
#ifndef GUI_H
#define GUI_H
#include "lexos.h"

#define GUI_FN static __attribute__((unused))

static unsigned *g_frame;
static int g_w, g_h;
static unsigned char g_font[4096];

GUI_FN int gui_open(int w, int h)
{
    if (gfx_mode_ex(w, h, 32) < 0) return -1;
    g_frame = malloc(w * h * 4);
    if (!g_frame) return -1;
    g_w = w; g_h = h;
    font(g_font);
    return 0;
}
/* the picture (the window) another size - where it is - and a new frame */
GUI_FN int gui_resize(int w, int h)
{
    if (gfx_mode_ex(w, h, 32) < 0) return -1;
    free(g_frame);
    g_frame = malloc(w * h * 4);
    if (!g_frame) return -1;
    g_w = w; g_h = h;
    return 0;
}
GUI_FN void gui_show(void) { gfx_blit(g_frame); }
GUI_FN void gui_show_rect(int x, int y, int w, int h) { gfx_blit_rect(g_frame, x, y, w, h); }

GUI_FN void gui_fill(int x, int y, int w, int h, unsigned c)
{
    int i, j;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > g_w) w = g_w - x;
    if (y + h > g_h) h = g_h - y;
    for (j = 0; j < h; j++) {
        unsigned *p = g_frame + (y + j) * g_w + x;
        for (i = 0; i < w; i++) p[i] = c;
    }
}
GUI_FN void gui_box(int x, int y, int w, int h, unsigned c)     /* an outline */
{
    gui_fill(x, y, w, 1, c);
    gui_fill(x, y + h - 1, w, 1, c);
    gui_fill(x, y, 1, h, c);
    gui_fill(x + w - 1, y, 1, h, c);
}
GUI_FN void gui_pixel(int x, int y, unsigned c)
{
    if (x >= 0 && y >= 0 && x < g_w && y < g_h) g_frame[y * g_w + x] = c;
}
/* a + (b - a) * t / 256, per channel */
GUI_FN unsigned gui_mix(unsigned a, unsigned b, int t)
{
    int r = (a >> 16 & 255) + (((int)(b >> 16 & 255) - (int)(a >> 16 & 255)) * t >> 8);
    int g = (a >> 8 & 255) + (((int)(b >> 8 & 255) - (int)(a >> 8 & 255)) * t >> 8);
    int l = (a & 255) + (((int)(b & 255) - (int)(a & 255)) * t >> 8);
    return RGB(r, g, l);
}
/* a rectangle with its corners cut by r pixels (r up to 8) */
GUI_FN void gui_round(int x, int y, int w, int h, int r, unsigned c)
{
    static const unsigned char cut[9][8] = {
        {0}, {1}, {2, 1}, {3, 1, 1}, {4, 2, 1, 1}, {5, 3, 2, 1, 1},
        {6, 4, 3, 2, 1, 1}, {7, 5, 3, 2, 2, 1, 1}, {8, 6, 4, 3, 2, 1, 1, 1}
    };
    int j;
    if (r > 8) r = 8;
    for (j = 0; j < h; j++) {
        int k = 0;
        if (j < r) k = cut[r][j];
        else if (j >= h - r) k = cut[r][h - 1 - j];
        gui_fill(x + k, y + j, w - 2 * k, 1, c);
    }
}

GUI_FN void gui_glyph(int x, int y, unsigned char ch, unsigned c, int k)
{
    int r, b;
    const unsigned char *g = g_font + ch * 16;
    for (r = 0; r < 16 * k; r++) {
        unsigned bits = g[r / k];
        if (!bits || y + r < 0 || y + r >= g_h) continue;
        for (b = 0; b < 8 * k; b++)
            if (bits & (0x80 >> (b / k)) && x + b >= 0 && x + b < g_w) g_frame[(y + r) * g_w + x + b] = c;
    }
}
GUI_FN void gui_text(int x, int y, const char *t, unsigned c, int k)
{
    while (*t) { gui_glyph(x, y, (unsigned char)*t++, c, k); x += 8 * k; }
}
GUI_FN int gui_text_w(const char *t, int k) { return 8 * k * (int)strlen(t); }
GUI_FN void gui_text_c(int cx, int y, const char *t, unsigned c, int k)  /* centered on cx */
{
    gui_text(cx - gui_text_w(t, k) / 2, y, t, c, k);
}
/* at most n characters of t, the rest cut to "..." */
GUI_FN void gui_text_n(int x, int y, const char *t, int n, unsigned c)
{
    int i, len = strlen(t);
    for (i = 0; i < len && i < n; i++) {
        unsigned char ch = (unsigned char)t[i];
        if (len > n && i >= n - 3) ch = '.';
        gui_glyph(x + i * 8, y, ch, c, 1);
    }
}

/* v -> decimal text in buf (returns buf) */
static char *gui_num(char *buf, int v)
{
    char t[12];
    int i = 0, n = 0;
    unsigned u = v < 0 ? -(unsigned)v : (unsigned)v;
    do { t[i++] = '0' + u % 10; u /= 10; } while (u);
    if (v < 0) buf[n++] = '-';
    while (i) buf[n++] = t[--i];
    buf[n] = 0;
    return buf;
}
GUI_FN void gui_cat(char *d, const char *s) { strcpy(d + strlen(d), s); }

/* ---- numbers kept between runs: /SYSTEM/APPS.CFG ---- */
#define GUI_CFG "/SYSTEM/APPS.CFG"
#define GUI_CFG_MAX 4096

GUI_FN int gui_cfg_load(char *buf)
{
    int fd = open(GUI_CFG, O_READ), n = 0;
    if (fd >= 0) { n = read(fd, buf, GUI_CFG_MAX - 1); close(fd); }
    if (n < 0) n = 0;
    buf[n] = 0;
    return n;
}
/* -> where "key=" starts a line in buf, or -1 */
GUI_FN int gui_cfg_find(const char *buf, const char *key)
{
    int i = 0, kl = strlen(key);
    while (buf[i]) {
        if (!memcmp(buf + i, key, kl) && buf[i + kl] == '=') return i;
        while (buf[i] && buf[i] != '\n') i++;
        if (buf[i]) i++;
    }
    return -1;
}
GUI_FN int gui_cfg_get(const char *key, int def)
{
    static char buf[GUI_CFG_MAX];
    int at;
    gui_cfg_load(buf);
    at = gui_cfg_find(buf, key);
    return at < 0 ? def : atoi(buf + at + strlen(key) + 1);
}
GUI_FN void gui_cfg_set(const char *key, int v)
{
    static char buf[GUI_CFG_MAX];
    char line[48];
    int n = gui_cfg_load(buf), at = gui_cfg_find(buf, key), fd;
    if (at >= 0) {                                   /* the old line out */
        int e = at;
        while (buf[e] && buf[e] != '\n') e++;
        if (buf[e]) e++;
        memmove(buf + at, buf + e, n - e + 1);
        n -= e - at;
    }
    strcpy(line, key);
    gui_cat(line, "=");
    gui_num(line + strlen(line), v);
    gui_cat(line, "\n");
    if (n + (int)strlen(line) >= GUI_CFG_MAX) return;
    strcpy(buf + n, line);
    fd = open(GUI_CFG, O_WRITE);
    if (fd < 0) return;
    fwrite(fd, buf, strlen(buf));
    close(fd);
}

/* a button: its face, its words centered; hot = under the pointer */
GUI_FN void gui_button(int x, int y, int w, int h, const char *t, int hot)
{
    gui_round(x, y, w, h, 3, hot ? RGB(200, 216, 246) : RGB(226, 230, 238));
    gui_text_c(x + w / 2, y + (h - 16) / 2, t, RGB(28, 30, 36), 1);
}
GUI_FN int gui_in(int mx, int my, int x, int y, int w, int h)
{
    return mx >= x && my >= y && mx < x + w && my < y + h;
}

#endif
