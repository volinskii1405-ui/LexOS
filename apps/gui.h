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

/* ---- a text field: typing into buf (n bytes), Backspace ---- */
GUI_FN void gui_field_key(char *buf, int n, int ch)
{
    int l = strlen(buf);
    if (ch == 8) { if (l) buf[l - 1] = 0; return; }
    if (ch >= 32 && ch != 127 && l < n - 1) { buf[l] = ch; buf[l + 1] = 0; }
}
GUI_FN void gui_field(int x, int y, int w, const char *t, int focus)
{
    int n = (w - 12) / 8, l = strlen(t), from = l > n - 1 ? l - (n - 1) : 0;
    gui_fill(x, y, w, 24, RGB(255, 255, 255));
    gui_box(x, y, w, 24, focus ? RGB(40, 90, 200) : RGB(170, 180, 198));
    gui_text(x + 6, y + 4, t + from, RGB(28, 30, 36), 1);
    if (focus) gui_fill(x + 6 + (l - from) * 8, y + 4, 2, 16, RGB(40, 90, 200));
}
/* Ctrl + a letter? (with keymode(1) it comes as its control code, 1-26,
 * even if Ctrl's already up by the time it's read) */
GUI_FN int gui_ctrl(int ch, int sc)
{
    if (ch >= 1 && ch <= 26 && sc != 0x0E && sc != 0x0F && sc != 0x1C) return 1;
    return keydown(KEY_CTRL);
}
GUI_FN char gui_upper(char c) { return c >= 'a' && c <= 'z' ? c - 32 : c; }

/* ---- a file to open, or a name to save as ----
 * A box over the picture: the folder's list (folders first; with exts,
 * "WAV MOD", only files with one of those extensions), a name to type,
 * OK and Cancel. Runs until one's chosen: path is where it starts (a
 * folder, or a file's path) and, on 1, the chosen file's path; 0 if it
 * was cancelled. What was under the box is put back. */
#define GUI_DLG_MAX 200
static struct lx_dirent g_dents[GUI_DLG_MAX];
static int g_ndents;

GUI_FN int gui_ext_ok(const char *name, const char *exts)
{
    const char *e = name, *p;
    int i;
    if (!exts) return 1;
    for (p = name; *p; p++) if (*p == '.') e = p + 1;
    if (e == name) return 0;
    for (p = exts; *p; ) {
        for (i = 0; e[i] && p[i] && p[i] != ' ' && gui_upper(e[i]) == p[i]; i++);
        if (!e[i] && (!p[i] || p[i] == ' ')) return 1;
        while (*p && *p != ' ') p++;
        while (*p == ' ') p++;
    }
    return 0;
}
GUI_FN void gui_dlg_list(const char *dir, const char *exts)
{
    struct lx_dirent e;
    int i, j;
    g_ndents = 0;
    if (strcmp(dir, "/")) { memset(&g_dents[0], 0, sizeof e); strcpy(g_dents[0].name, ".."); g_dents[0].type = LX_DIR; g_ndents = 1; }
    for (i = 0; g_ndents < GUI_DLG_MAX && readdir(dir, i, &e) == 0; i++)
        if (e.type == LX_DIR || gui_ext_ok(e.name, exts)) g_dents[g_ndents++] = e;
    for (i = 1; i < g_ndents; i++) {                /* folders first, by name */
        struct lx_dirent t = g_dents[i];
        int tk = t.type == LX_DIR ? 0 : 1;
        for (j = i; j > 0 && strcmp(g_dents[j - 1].name, ".."); j--) {
            int pk = g_dents[j - 1].type == LX_DIR ? 0 : 1;
            if (pk < tk || (pk == tk && strcmp(g_dents[j - 1].name, t.name) <= 0)) break;
            g_dents[j] = g_dents[j - 1];
        }
        g_dents[j] = t;
    }
}
GUI_FN int gui_file_dialog(const char *title, char *path, int save, const char *exts)
{
    char dir[128], name[64];
    unsigned *under;
    int bw = g_w - 40 < 520 ? g_w - 40 : 520, bh = g_h - 40 < 420 ? g_h - 40 : 420;
    int bx = (g_w - bw) / 2, by = (g_h - bh) / 2;
    int ly = by + 36, lh = bh - 36 - 80, rows = lh / 18, top = 0, sel = -1;
    int m[4], was = 1, hot = -1, result = -1, i;
    unsigned last = 0;
    /* where to start: path's folder, its name in the field */
    strcpy(dir, "/"); name[0] = 0;
    if (path[0] == '/') {
        int cut = 0, l = strlen(path);
        for (i = 0; i < l; i++) if (path[i] == '/') cut = i;
        if (l < (int)sizeof dir) {
            struct lx_dirent e;
            int is_dir = 0;
            /* a folder itself? (then all of it is the folder) */
            if (l > 1) {
                char up[128]; memcpy(up, path, cut); up[cut ? cut : 1] = 0; if (!cut) strcpy(up, "/");
                for (i = 0; readdir(up, i, &e) == 0; i++)
                    if (e.type == LX_DIR && !strcmp(e.name, path + cut + 1)) is_dir = 1;
            } else is_dir = 1;
            if (is_dir) strcpy(dir, path);
            else {
                if (cut) { memcpy(dir, path, cut); dir[cut] = 0; }
                if (strlen(path + cut + 1) < sizeof name) strcpy(name, path + cut + 1);
            }
        }
    }
    under = malloc(g_w * g_h * 4);
    if (under) memcpy(under, g_frame, g_w * g_h * 4);
    gui_dlg_list(dir, exts);
    while (result < 0) {
        int k, changed = 0;
        /* ---- keys ---- */
        while ((k = pollkey())) {
            int ch = k & 0xFF, sc = (k >> 8) & 0xFF;
            changed = 1;
            if (sc == KEY_ESC) { result = 0; break; }
            if (ch == 13) { result = 2; break; }       /* (2: as OK) */
            if (sc == KEY_UP && !ch) { if (sel > 0) sel--; }
            else if (sc == KEY_DOWN && !ch) { if (sel < g_ndents - 1) sel++; }
            else { gui_field_key(name, sizeof name, gui_upper(ch)); continue; }
            if (sel >= 0 && g_dents[sel].type != LX_DIR) strcpy(name, g_dents[sel].name);
            if (sel >= 0 && sel < top) top = sel;
            if (sel >= top + rows) top = sel - rows + 1;
        }
        /* ---- the mouse ---- */
        if (result < 0 && mouse(m)) {
            int mx = m[0], my = m[1], down = m[2] & 1, h = -1;
            if (m[3]) { top += m[3] * 3; changed = 1; }
            if (gui_in(mx, my, bx + bw - 212, by + bh - 38, 96, 28)) h = 1;
            else if (gui_in(mx, my, bx + bw - 108, by + bh - 38, 96, 28)) h = 2;
            if (h != hot) { hot = h; changed = 1; }
            if (down && !was) {
                changed = 1;
                if (h == 1) result = 2;
                else if (h == 2) result = 0;
                else if (gui_in(mx, my, bx + 12, ly, bw - 24, lh)) {
                    int r = top + (my - ly) / 18;
                    unsigned now = millis();
                    if (r < g_ndents) {
                        if (r == sel && now - last < 450) result = 3;   /* a double click */
                        sel = r;
                        if (g_dents[r].type != LX_DIR) strcpy(name, g_dents[r].name);
                    }
                    last = now;
                }
            }
            was = down;
        }
        if (top > g_ndents - rows) top = g_ndents - rows;
        if (top < 0) top = 0;
        /* OK (2), or a double click (3): into a folder, or done */
        if (result >= 2) {
            const char *pick = name;
            int into = -1;
            if (result == 3 && sel >= 0 && g_dents[sel].type == LX_DIR) into = sel;
            for (i = 0; i < g_ndents && into < 0 && name[0]; i++)
                if (g_dents[i].type == LX_DIR && !strcmp(g_dents[i].name, name)) into = i;
            if (into < 0 && result == 2 && !name[0] && sel >= 0 && g_dents[sel].type == LX_DIR) into = sel;
            if (into >= 0) {
                const char *d = g_dents[into].name;
                if (!strcmp(d, "..")) { int c = 0; for (i = 0; dir[i]; i++) if (dir[i] == '/') c = i; dir[c ? c : 1] = 0; }
                else { if (strcmp(dir, "/")) gui_cat(dir, "/"); gui_cat(dir, d); }
                gui_dlg_list(dir, exts);
                sel = -1; top = 0; name[0] = 0; result = -1; changed = 1;
            } else if (!pick[0]) result = -1;
            else if (!save) {
                int found = 0;
                for (i = 0; i < g_ndents; i++) if (!strcmp(g_dents[i].name, pick)) found = 1;
                if (!found) result = -1;
            }
            if (result >= 2) {
                strcpy(path, dir);
                if (strcmp(dir, "/")) gui_cat(path, "/");
                gui_cat(path, pick);
                result = 1;
            }
        }
        if (changed || result >= 0) {
            gui_fill(bx + 4, by + 4, bw, bh, RGB(90, 96, 110));            /* a shadow */
            gui_fill(bx, by, bw, bh, RGB(244, 246, 250));
            gui_box(bx, by, bw, bh, RGB(120, 130, 150));
            gui_fill(bx, by, bw, 28, RGB(40, 90, 200));
            gui_text(bx + 10, by + 6, title, RGB(255, 255, 255), 1);
            gui_text_n(bx + 16 + gui_text_w(title, 1), by + 6, dir, (bw - 30 - gui_text_w(title, 1)) / 8, RGB(200, 216, 246));
            gui_fill(bx + 12, ly, bw - 24, lh, RGB(255, 255, 255));
            gui_box(bx + 12, ly, bw - 24, lh, RGB(200, 206, 218));
            for (i = 0; i < rows && top + i < g_ndents; i++) {
                struct lx_dirent *e = &g_dents[top + i];
                int y = ly + 2 + i * 18;
                char sz[16];
                if (top + i == sel) gui_fill(bx + 13, y - 1, bw - 26, 18, RGB(206, 222, 250));
                if (e->type == LX_DIR) {                            /* a folder */
                    gui_fill(bx + 20, y + 3, 14, 10, RGB(240, 190, 60));
                    gui_fill(bx + 20, y + 1, 6, 3, RGB(240, 190, 60));
                } else {
                    gui_fill(bx + 22, y + 1, 10, 14, RGB(255, 255, 255));
                    gui_box(bx + 22, y + 1, 10, 14, RGB(140, 150, 170));
                }
                gui_text_n(bx + 42, y, e->name, 16, RGB(28, 30, 36));
                if (e->type != LX_DIR) {
                    gui_num(sz, e->size);
                    gui_text(bx + bw - 24 - gui_text_w(sz, 1), y, sz, RGB(120, 126, 138), 1);
                }
            }
            gui_text(bx + 12, by + bh - 72, save ? "Save as:" : "Name:", RGB(90, 96, 110), 1);
            gui_field(bx + 90, by + bh - 76, bw - 102, name, 1);
            gui_button(bx + bw - 212, by + bh - 38, 96, 28, save ? "Save" : "Open", hot == 1);
            gui_button(bx + bw - 108, by + bh - 38, 96, 28, "Cancel", hot == 2);
            gui_show();
        }
        sleep_ms(15);
    }
    if (under) { memcpy(g_frame, under, g_w * g_h * 4); free(under); gui_show(); }
    return result == 1;
}

#endif
