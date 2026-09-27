/* sweeper.c - LexOS Minesweeper, in a window.
 *
 *   run sweeper.app
 *
 * Left click opens a cell (the first one is never a mine), right click
 * puts a flag on it (or takes it off). A click on an opened number
 * whose flags are all placed opens the cells around it. The face (or
 * F2) starts again; 1 2 3 pick Beginner (9x9, 10 mines), Intermediate
 * (16x16, 40) or Expert (30x16, 99). Esc quits. The best time of each
 * is kept (/SYSTEM/APPS.CFG, "sweeper1=" ...). */
#include "gui.h"

#define CELL 24
#define MAXC 30
#define MAXR 16
#define TOP 64
#define PAD 12
/* the window fits the board: at least wide enough for the level buttons */
#define W g_w
#define H g_h
static int win_w(int c) { int w = PAD * 2 + c * CELL; w = w < 384 ? 384 : w; return (w + 7) & ~7; }
static int win_h(int r) { return TOP + r * CELL + PAD + 28; }

#define C_BG     RGB(236, 239, 244)
#define C_BAR    RGB(52, 64, 90)
#define C_CLOSED RGB(170, 200, 238)
#define C_CLOSED2 RGB(160, 192, 232)
#define C_HOT    RGB(196, 218, 248)
#define C_OPEN   RGB(248, 249, 252)
#define C_LINE   RGB(214, 219, 228)
#define C_MINE   RGB(40, 40, 48)
#define C_BOOM   RGB(236, 84, 70)
#define C_FLAG   RGB(226, 50, 40)

static const unsigned num_color[9] = {
    0, RGB(40, 90, 220), RGB(40, 150, 60), RGB(220, 50, 50), RGB(40, 40, 150),
    RGB(150, 40, 40), RGB(20, 140, 150), RGB(30, 30, 30), RGB(120, 120, 120)
};
static const int lv_c[3] = { 9, 16, 30 }, lv_r[3] = { 9, 16, 16 }, lv_m[3] = { 10, 40, 99 };

static unsigned char mine[MAXR][MAXC], open_[MAXR][MAXC], flag[MAXR][MAXC], near[MAXR][MAXC];
static int cols, rows, mines, level, state;        /* 0 not started, 1 playing, 2 lost, 3 won */
static int flags, opened, boom_x = -1, boom_y = -1;
static unsigned t_start, t_end;
static int best[3], hot_x = -1, hot_y = -1, face_hot, lv_hot = -1;
static unsigned seed;

static unsigned rnd(void) { seed = seed * 1103515245 + 12345; return seed >> 16; }
static int bx0(void) { return (W - cols * CELL) / 2; }

static void new_game(int lv)
{
    level = lv;
    cols = lv_c[lv]; rows = lv_r[lv]; mines = lv_m[lv];
    if (g_w != win_w(cols) || g_h != win_h(rows)) gui_resize(win_w(cols), win_h(rows));
    memset(mine, 0, sizeof mine); memset(open_, 0, sizeof open_);
    memset(flag, 0, sizeof flag); memset(near, 0, sizeof near);
    state = 0; flags = 0; opened = 0; boom_x = boom_y = -1;
}
/* mines everywhere but around (sx, sy), where the first click was */
static void lay(int sx, int sy)
{
    int n = 0, x, y, dx, dy;
    while (n < mines) {
        x = rnd() % cols; y = rnd() % rows;
        if (mine[y][x] || (x - sx <= 1 && sx - x <= 1 && y - sy <= 1 && sy - y <= 1)) continue;
        mine[y][x] = 1; n++;
    }
    for (y = 0; y < rows; y++)
        for (x = 0; x < cols; x++)
            for (dy = -1; dy <= 1; dy++)
                for (dx = -1; dx <= 1; dx++) {
                    int a = x + dx, b = y + dy;
                    if (a >= 0 && b >= 0 && a < cols && b < rows && mine[b][a]) near[y][x]++;
                }
    state = 1;
    t_start = millis();
}
static void finish(int won)
{
    state = won ? 3 : 2;
    t_end = millis();
    if (won) {
        int secs = (t_end - t_start) / 1000;
        char key[12] = "sweeper1";
        key[7] = '1' + level;
        if (!best[level] || secs < best[level]) { best[level] = secs; gui_cfg_set(key, secs); }
        beep(1200, 120);
    } else beep(120, 300);
}
static void reveal(int x, int y)
{
    static short stack[MAXC * MAXR * 2];
    int sp = 0;
    stack[sp++] = x; stack[sp++] = y;
    while (sp) {
        int cy = stack[--sp], cx = stack[--sp], dx, dy;
        if (open_[cy][cx] || flag[cy][cx]) continue;
        open_[cy][cx] = 1;
        opened++;
        if (mine[cy][cx]) { boom_x = cx; boom_y = cy; finish(0); return; }
        if (near[cy][cx]) continue;
        for (dy = -1; dy <= 1; dy++)
            for (dx = -1; dx <= 1; dx++) {
                int a = cx + dx, b = cy + dy;
                if (a >= 0 && b >= 0 && a < cols && b < rows && !open_[b][a] && !flag[b][a] && sp < MAXC * MAXR * 2 - 2) {
                    stack[sp++] = a; stack[sp++] = b;
                }
            }
    }
    if (opened == cols * rows - mines) {
        int a, b;
        for (b = 0; b < rows; b++) for (a = 0; a < cols; a++) if (mine[b][a] && !flag[b][a]) { flag[b][a] = 1; flags++; }
        finish(1);
    }
}
static void chord(int x, int y)             /* a number whose flags are all there */
{
    int dx, dy, f = 0;
    for (dy = -1; dy <= 1; dy++)
        for (dx = -1; dx <= 1; dx++) {
            int a = x + dx, b = y + dy;
            if (a >= 0 && b >= 0 && a < cols && b < rows && flag[b][a]) f++;
        }
    if (f != near[y][x]) return;
    for (dy = -1; dy <= 1 && state == 1; dy++)
        for (dx = -1; dx <= 1 && state == 1; dx++) {
            int a = x + dx, b = y + dy;
            if (a >= 0 && b >= 0 && a < cols && b < rows && !open_[b][a] && !flag[b][a]) reveal(a, b);
        }
}

/* ---- drawing ---- */
static void draw_mine(int x, int y)
{
    gui_round(x + 6, y + 6, 12, 12, 5, C_MINE);
    gui_fill(x + 11, y + 3, 2, 18, C_MINE);
    gui_fill(x + 3, y + 11, 18, 2, C_MINE);
    gui_fill(x + 9, y + 9, 3, 3, RGB(255, 255, 255));
}
static void draw_flag(int x, int y)
{
    gui_fill(x + 11, y + 5, 2, 14, C_MINE);
    gui_fill(x + 6, y + 18, 12, 2, C_MINE);
    gui_fill(x + 5, y + 5, 7, 7, C_FLAG);
}
static void draw_face(int x, int y, int hot)
{
    unsigned c = state == 2 ? RGB(250, 150, 120) : state == 3 ? RGB(140, 220, 120) : RGB(255, 214, 70);
    gui_round(x, y, 36, 36, 8, hot ? RGB(90, 110, 150) : RGB(70, 86, 118));
    gui_round(x + 4, y + 4, 28, 28, 8, c);
    if (state == 2) {                                    /* x x */
        gui_text(x + 9, y + 7, "x", C_MINE, 1);
        gui_text(x + 19, y + 7, "x", C_MINE, 1);
    } else {
        gui_fill(x + 12, y + 12, 3, 4, C_MINE);
        gui_fill(x + 21, y + 12, 3, 4, C_MINE);
    }
    if (state == 3) { gui_fill(x + 9, y + 10, 18, 4, C_MINE); }   /* sunglasses */
    if (state == 2) gui_fill(x + 13, y + 24, 10, 2, C_MINE);
    else { gui_fill(x + 12, y + 23, 12, 2, C_MINE); gui_fill(x + 10, y + 21, 2, 2, C_MINE); gui_fill(x + 24, y + 21, 2, 2, C_MINE); }
}
static void draw(void)
{
    int x, y, i;
    char t[32], n[12];
    unsigned secs = state == 1 ? (millis() - t_start) / 1000 : state >= 2 ? (t_end - t_start) / 1000 : 0;
    static const char *names[3] = { "Beginner", "Intermediate", "Expert" };
    gui_fill(0, 0, W, H, C_BG);
    gui_fill(0, 0, W, TOP - 10, C_BAR);
    /* mines left, the face, the time */
    gui_round(PAD, 10, 84, 34, 4, RGB(24, 28, 40));
    gui_text(PAD + 10, 16, gui_num(n, mines - flags), RGB(255, 90, 80), 1);
    gui_text(PAD + 10 + gui_text_w(n, 1) + 6, 16, "mines", RGB(170, 180, 200), 1);
    draw_face(W / 2 - 18, 9, face_hot);
    gui_round(W - PAD - 84, 10, 84, 34, 4, RGB(24, 28, 40));
    strcpy(t, gui_num(n, secs > 999 ? 999 : secs));
    gui_text(W - PAD - 74, 16, t, RGB(255, 90, 80), 1);
    gui_text(W - PAD - 74 + gui_text_w(t, 1) + 6, 16, "s", RGB(170, 180, 200), 1);
    for (y = 0; y < rows; y++)
        for (x = 0; x < cols; x++) {
            int cx = bx0() + x * CELL, cy = TOP + y * CELL;
            if (open_[y][x] || (state == 2 && mine[y][x])) {
                gui_fill(cx, cy, CELL, CELL, x == boom_x && y == boom_y ? C_BOOM : C_OPEN);
                gui_box(cx, cy, CELL, CELL, C_LINE);
                if (mine[y][x]) draw_mine(cx, cy);
                else if (near[y][x]) gui_glyph(cx + 8, cy + 4, '0' + near[y][x], num_color[near[y][x]], 1);
                if (state == 2 && flag[y][x] && mine[y][x]) draw_flag(cx, cy);
            } else {
                unsigned c = (x == hot_x && y == hot_y && state < 2) ? C_HOT : (x + y) & 1 ? C_CLOSED2 : C_CLOSED;
                gui_fill(cx, cy, CELL, CELL, c);
                gui_fill(cx, cy, CELL, 1, gui_mix(c, RGB(255, 255, 255), 120));
                gui_fill(cx, cy + CELL - 1, CELL, 1, gui_mix(c, 0, 50));
                if (flag[y][x]) {
                    draw_flag(cx, cy);
                    if (state == 2 && !mine[y][x]) { gui_fill(cx + 4, cy + 11, 16, 2, C_MINE); }  /* a wrong one */
                }
            }
        }
    /* the bottom line: the levels, the best time */
    y = TOP + rows * CELL + 8;
    x = PAD;
    for (i = 0; i < 3; i++) {
        int bw = gui_text_w(names[i], 1) + 30;
        gui_round(x, y, bw, 24, 3, i == level ? RGB(52, 64, 90) : i == lv_hot ? RGB(206, 218, 240) : RGB(222, 226, 234));
        t[0] = '1' + i; t[1] = ' '; strcpy(t + 2, names[i]);
        gui_text(x + 8, y + 4, t, i == level ? RGB(255, 255, 255) : RGB(40, 44, 56), 1);
        x += bw + 6;
    }
    if (best[level]) {                              /* the best time: by the face */
        strcpy(t, "Best ");
        gui_cat(t, gui_num(n, best[level]));
        gui_text_c((PAD + 84 + W / 2 - 18) / 2, 20, t, RGB(170, 180, 200), 1);
    }
    if (state >= 2) {
        const char *msg = state == 3 ? "Cleared!" : "Boom!";
        int bw = 220;
        gui_round(W / 2 - bw / 2, TOP + rows * CELL / 2 - 34, bw, 60, 8, RGB(40, 48, 70));
        gui_text_c(W / 2, TOP + rows * CELL / 2 - 26, msg, RGB(255, 255, 255), 2);
        gui_text_c(W / 2, TOP + rows * CELL / 2 + 4, "the face or F2: again", RGB(190, 200, 220), 1);
    }
    gui_show();
}
/* the bottom line's level button at (mx, my), or -1 */
static int level_at(int mx, int my)
{
    static const char *names[3] = { "Beginner", "Intermediate", "Expert" };
    int i, x = PAD, y = TOP + rows * CELL + 8;
    for (i = 0; i < 3; i++) {
        int bw = gui_text_w(names[i], 1) + 30;
        if (gui_in(mx, my, x, y, bw, 24)) return i;
        x += bw + 6;
    }
    return -1;
}

int main(void)
{
    int m[4], was = 0, last_secs = -1;
    seed = millis();
    best[0] = gui_cfg_get("sweeper1", 0);
    best[1] = gui_cfg_get("sweeper2", 0);
    best[2] = gui_cfg_get("sweeper3", 0);
    level = gui_cfg_get("sweeperlv", 0);
    if (level < 0 || level > 2) level = 0;
    if (gui_open(win_w(lv_c[level]), win_h(lv_r[level])) < 0) { puts("sweeper: needs a window in 32 bits\n"); return 1; }
    new_game(level);
    draw();
    for (;;) {
        int k, changed = 0;
        while ((k = pollkey())) {
            int c = k & 0xFF, sc = (k >> 8) & 0xFF;
            if (sc == KEY_ESC) return 0;
            if (sc == 0x3C || c == 'r' || c == 'R') new_game(level);        /* F2 */
            else if (c >= '1' && c <= '3') { new_game(c - '1'); gui_cfg_set("sweeperlv", level); }
            changed = 1;
        }
        if (mouse(m)) {
            int mx = m[0], my = m[1], b = m[2], x, y, fh, lh;
            int in = mx >= bx0() && my >= TOP && mx < bx0() + cols * CELL && my < TOP + rows * CELL;
            x = in ? (mx - bx0()) / CELL : -1;
            y = in ? (my - TOP) / CELL : -1;
            fh = gui_in(mx, my, W / 2 - 18, 9, 36, 36);
            lh = level_at(mx, my);
            if (x != hot_x || y != hot_y || fh != face_hot || lh != lv_hot) { hot_x = x; hot_y = y; face_hot = fh; lv_hot = lh; changed = 1; }
            if (b && !was) {
                changed = 1;
                if (fh) new_game(level);
                else if (lh >= 0) { new_game(lh); gui_cfg_set("sweeperlv", level); }
                else if (in && state < 2) {
                    if (b & 2) {
                        if (!open_[y][x]) { flag[y][x] ^= 1; flags += flag[y][x] ? 1 : -1; }
                    } else if (b & 1) {
                        if (state == 0) { if (!flag[y][x]) { lay(x, y); reveal(x, y); } }
                        else if (open_[y][x]) chord(x, y);
                        else if (!flag[y][x]) reveal(x, y);
                    }
                }
            }
            was = b;
        } else if (hot_x >= 0 || face_hot || lv_hot >= 0) { hot_x = hot_y = -1; face_hot = 0; lv_hot = -1; changed = 1; was = 0; }
        if (state == 1 && (int)((millis() - t_start) / 1000) != last_secs) { last_secs = (millis() - t_start) / 1000; changed = 1; }
        if (changed) draw();
        sleep_ms(15);
    }
    return 0;
}
