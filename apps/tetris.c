/* tetris.c - LexOS Tetris, in a window.
 *
 *   run tetris.app
 *
 * Left / Right move, Up (or X) turns, Z turns the other way, Down drops
 * faster, Space drops at once, C keeps the piece aside (hold) for
 * later. P pauses, Esc quits. Lines give 100 / 300 / 500 / 800 times
 * the level; every 10 lines is a level, and a quicker fall. The ghost
 * shows where the piece would land. The best score is kept
 * (/SYSTEM/APPS.CFG, "tetris="). */
#include "gui.h"

#define COLS 10
#define ROWS 20
#define CELL 24
#define BX 20
#define BY 20
#define SIDE_X (BX + COLS * CELL + 24)
#define W (SIDE_X + 150)
#define H (BY + ROWS * CELL + 20)

#define C_BG    RGB(30, 33, 46)
#define C_WELL  RGB(18, 20, 28)
#define C_GRID  RGB(34, 37, 50)
#define C_TEXT  RGB(230, 232, 240)
#define C_DIM   RGB(140, 146, 166)

static const unsigned colors[8] = {
    0, RGB(0, 200, 230), RGB(240, 200, 0), RGB(170, 70, 220), RGB(60, 200, 90),
    RGB(230, 60, 60), RGB(50, 110, 230), RGB(240, 140, 30)
};
/* I O T S Z J L: four cells each, in a 4x4 box, the spawn way round */
static const int shapes[8][4][2] = {
    {{0}}, {{0,1},{1,1},{2,1},{3,1}}, {{1,0},{2,0},{1,1},{2,1}}, {{1,0},{0,1},{1,1},{2,1}},
    {{1,0},{2,0},{0,1},{1,1}}, {{0,0},{1,0},{1,1},{2,1}}, {{0,0},{0,1},{1,1},{2,1}}, {{2,0},{0,1},{1,1},{2,1}}
};

static unsigned char board[ROWS][COLS];
static int px[4], py[4];                  /* the falling piece's cells */
static int kind, x0, y0, rot;
static int next_kind, hold_kind, held;
static int score, lines, level, best, over, paused;
static int bag[7], bag_n;
static unsigned seed;

static unsigned rnd(void) { seed = seed * 1103515245 + 12345; return seed >> 16; }
static int from_bag(void)                 /* each of the 7, in a random order */
{
    int i;
    if (!bag_n) {
        for (i = 0; i < 7; i++) bag[i] = i + 1;
        for (i = 6; i > 0; i--) { int j = rnd() % (i + 1), t = bag[i]; bag[i] = bag[j]; bag[j] = t; }
        bag_n = 7;
    }
    return bag[--bag_n];
}

/* the cells of kind k turned r times, at (x, y) -> cx/cy */
static void cells(int k, int r, int x, int y, int *cx, int *cy)
{
    int i, n = k == 1 ? 4 : 3;            /* I turns in 4x4, O not at all, the rest in 3x3 */
    for (i = 0; i < 4; i++) {
        int a = shapes[k][i][0], b = shapes[k][i][1], j, t;
        if (k != 2)
            for (j = 0; j < (r & 3); j++) { t = a; a = n - 1 - b; b = t; }
        cx[i] = x + a; cy[i] = y + b;
    }
}
static int fits(int k, int r, int x, int y)
{
    int cx[4], cy[4], i;
    cells(k, r, x, y, cx, cy);
    for (i = 0; i < 4; i++) {
        if (cx[i] < 0 || cx[i] >= COLS || cy[i] >= ROWS) return 0;
        if (cy[i] >= 0 && board[cy[i]][cx[i]]) return 0;
    }
    return 1;
}
static void spawn(int k)
{
    kind = k; rot = 0; x0 = 3; y0 = -1;
    if (!fits(kind, rot, x0, y0)) { y0 = -2; if (!fits(kind, rot, x0, y0)) {
        over = 1;
        if (score > best) { best = score; gui_cfg_set("tetris", best); }
        beep(150, 300);
    } }
    cells(kind, rot, x0, y0, px, py);
}
static void start(void)
{
    memset(board, 0, sizeof board);
    score = lines = 0; level = 1; over = paused = 0; held = 0; hold_kind = 0; bag_n = 0;
    next_kind = from_bag();
    spawn(from_bag());
}
static int try_move(int dx, int dy, int dr)
{
    /* a turn that doesn't fit is tried a step aside, then two, then up */
    static const int kicks[6][2] = { {0,0}, {-1,0}, {1,0}, {-2,0}, {2,0}, {0,-1} };
    int i, r = (rot + dr) & 3;
    for (i = 0; i < (dr ? 6 : 1); i++)
        if (fits(kind, r, x0 + dx + kicks[i][0], y0 + dy + kicks[i][1])) {
            x0 += dx + kicks[i][0]; y0 += dy + kicks[i][1]; rot = r;
            cells(kind, rot, x0, y0, px, py);
            return 1;
        }
    return 0;
}
static void lock(void)
{
    static const int pts[5] = { 0, 100, 300, 500, 800 };
    int i, y, n = 0;
    for (i = 0; i < 4; i++) {
        if (py[i] < 0) { over = 1; if (score > best) { best = score; gui_cfg_set("tetris", best); } return; }
        board[py[i]][px[i]] = kind;
    }
    for (y = ROWS - 1; y >= 0; y--) {
        int x, full = 1;
        for (x = 0; x < COLS; x++) if (!board[y][x]) full = 0;
        if (full) {
            memmove(board[1], board[0], y * COLS);
            memset(board[0], 0, COLS);
            n++; y++;
        }
    }
    if (n) {
        score += pts[n] * level;
        lines += n;
        level = lines / 10 + 1;
        beep(n == 4 ? 1400 : 1000, 40);
    } else beep(300, 8);
    held = 0;
    spawn(next_kind);
    next_kind = from_bag();
}
static void hard_drop(void)
{
    int d = 0;
    while (try_move(0, 1, 0)) d++;
    score += 2 * d;
    lock();
}
static void hold(void)
{
    int k = kind;
    if (held) return;
    if (hold_kind) spawn(hold_kind); else { spawn(next_kind); next_kind = from_bag(); }
    hold_kind = k;
    held = 1;
}

/* ---- drawing ---- */
static void block(int x, int y, unsigned c, int ghost)
{
    if (ghost) { gui_box(x + 1, y + 1, CELL - 2, CELL - 2, c); gui_box(x + 2, y + 2, CELL - 4, CELL - 4, gui_mix(c, C_WELL, 128)); return; }
    gui_fill(x + 1, y + 1, CELL - 2, CELL - 2, c);
    gui_fill(x + 1, y + 1, CELL - 2, 3, gui_mix(c, RGB(255, 255, 255), 90));
    gui_fill(x + 1, y + CELL - 4, CELL - 2, 3, gui_mix(c, 0, 80));
}
static void mini(int k, int x, int y)                /* a piece in the side panel */
{
    int cx[4], cy[4], i;
    if (!k) return;
    cells(k, 0, 0, 0, cx, cy);
    for (i = 0; i < 4; i++) {
        int s = CELL * 3 / 4;
        gui_fill(x + cx[i] * s + 1, y + cy[i] * s + 1, s - 2, s - 2, colors[k]);
    }
}
static void panel(int y, const char *label, int v)
{
    char n[12];
    gui_text(SIDE_X, y, label, C_DIM, 1);
    gui_text(SIDE_X, y + 18, gui_num(n, v), C_TEXT, 2);
}
static void draw(void)
{
    int x, y, i, gy = y0;
    gui_fill(0, 0, W, H, C_BG);
    gui_fill(BX - 2, BY - 2, COLS * CELL + 4, ROWS * CELL + 4, RGB(70, 76, 100));
    gui_fill(BX, BY, COLS * CELL, ROWS * CELL, C_WELL);
    for (y = 0; y < ROWS; y++)
        for (x = 0; x < COLS; x++) {
            gui_box(BX + x * CELL, BY + y * CELL, CELL, CELL, C_GRID);
            if (board[y][x]) block(BX + x * CELL, BY + y * CELL, colors[board[y][x]], 0);
        }
    if (!over) {
        int cx[4], cy[4];
        while (fits(kind, rot, x0, gy + 1)) gy++;         /* the ghost */
        cells(kind, rot, x0, gy, cx, cy);
        for (i = 0; i < 4; i++) if (cy[i] >= 0) block(BX + cx[i] * CELL, BY + cy[i] * CELL, colors[kind], 1);
        for (i = 0; i < 4; i++) if (py[i] >= 0) block(BX + px[i] * CELL, BY + py[i] * CELL, colors[kind], 0);
    }
    gui_text(SIDE_X, BY, "Next", C_DIM, 1);
    gui_round(SIDE_X, BY + 20, 110, 60, 4, C_WELL);
    mini(next_kind, SIDE_X + 14, BY + 34);
    gui_text(SIDE_X, BY + 92, "Hold  (C)", C_DIM, 1);
    gui_round(SIDE_X, BY + 112, 110, 60, 4, C_WELL);
    mini(hold_kind, SIDE_X + 14, BY + 126);
    panel(BY + 190, "Score", score);
    panel(BY + 244, "Lines", lines);
    panel(BY + 298, "Level", level);
    panel(BY + 352, "Best", best);
    gui_text(SIDE_X, H - 60, "P pause", C_DIM, 1);
    gui_text(SIDE_X, H - 40, "Esc quit", C_DIM, 1);
    if (over || paused) {
        int bw = COLS * CELL - 20;
        gui_round(BX + 10, BY + 170, bw, 110, 8, RGB(44, 48, 66));
        gui_text_c(BX + COLS * CELL / 2, BY + 186, over ? "Game over" : "Paused", C_TEXT, 2);
        gui_text_c(BX + COLS * CELL / 2, BY + 236, over ? "Space: again" : "P: go on", C_DIM, 1);
    }
    gui_show();
}

int main(void)
{
    unsigned next_fall, now;
    int m[4];
    if (gui_open(W, H) < 0) { puts("tetris: needs a 434x520 picture in 32 bits\n"); return 1; }
    seed = millis();
    best = gui_cfg_get("tetris", 0);
    start();
    draw();
    next_fall = millis();
    for (;;) {
        int k, changed = 0, interval;
        while ((k = pollkey())) {
            int c = k & 0xFF, sc = (k >> 8) & 0xFF;
            changed = 1;
            if (sc == KEY_ESC) return 0;
            if (over) { if (c == ' ' || c == '\r') { start(); next_fall = millis(); } continue; }
            if (c == 'p' || c == 'P') { paused = !paused; continue; }
            if (paused) continue;
            if (sc == KEY_LEFT) try_move(-1, 0, 0);
            else if (sc == KEY_RIGHT) try_move(1, 0, 0);
            else if (sc == KEY_DOWN) { if (try_move(0, 1, 0)) score++; next_fall = millis(); }
            else if (sc == KEY_UP || c == 'x' || c == 'X') try_move(0, 0, 1);
            else if (c == 'z' || c == 'Z') try_move(0, 0, 3);
            else if (c == ' ') hard_drop();
            else if (c == 'c' || c == 'C') hold();
        }
        mouse(m);
        now = millis();
        interval = 800 - (level - 1) * 70;
        if (interval < 80) interval = 80;
        if (!over && !paused && (int)(now - next_fall) >= interval) {
            if (!try_move(0, 1, 0)) lock();
            next_fall = now;
            changed = 1;
        }
        if (changed) draw();
        sleep_ms(10);
    }
    return 0;
}
