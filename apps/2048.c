/* g2048.c - LexOS 2048, in a window.
 *
 *   run 2048.app
 *
 * Arrows or WASD slide every tile; two alike that meet become one, twice
 * as big. Get a 2048 tile - and go on if you like. U (or Backspace)
 * takes the last move back, N starts again, Esc quits. The best score
 * is kept (/SYSTEM/APPS.CFG, "2048="). */
#include "gui.h"

#define N 4
#define TILE 96
#define GAP 12
#define BOARD (N * TILE + (N + 1) * GAP)
#define PAD 20
#define TOP 110
#define W (BOARD + PAD * 2)
#define H (TOP + BOARD + PAD + 20)

#define C_BG    RGB(250, 248, 239)
#define C_BOARD RGB(187, 173, 160)
#define C_EMPTY RGB(205, 193, 180)
#define C_DARK  RGB(119, 110, 101)
#define C_LIGHT RGB(249, 246, 242)

static int grid[N][N], undo_grid[N][N];
static int score, undo_score, best, can_undo, won, kept_on, over;
/* the last move, for its slide: where each tile came from */
static int from_x[N][N], from_y[N][N], merged[N][N], born[N][N];
static unsigned anim_start;
#define ANIM_MS 110
static unsigned seed;

static unsigned rnd(void) { seed = seed * 1103515245 + 12345; return seed >> 16; }

static void add_tile(void)
{
    int free_[N * N], n = 0, x, y, p;
    for (y = 0; y < N; y++) for (x = 0; x < N; x++) if (!grid[y][x]) free_[n++] = y * N + x;
    if (!n) return;
    p = free_[rnd() % n];
    grid[p / N][p % N] = rnd() % 10 ? 2 : 4;
    born[p / N][p % N] = 1;
}
static int moves_left(void)
{
    int x, y;
    for (y = 0; y < N; y++)
        for (x = 0; x < N; x++) {
            if (!grid[y][x]) return 1;
            if (x + 1 < N && grid[y][x] == grid[y][x + 1]) return 1;
            if (y + 1 < N && grid[y][x] == grid[y + 1][x]) return 1;
        }
    return 0;
}
static void start(void)
{
    memset(grid, 0, sizeof grid);
    memset(merged, 0, sizeof merged); memset(born, 0, sizeof born);
    score = 0; can_undo = 0; won = 0; kept_on = 0; over = 0;
    { int x, y; for (y = 0; y < N; y++) for (x = 0; x < N; x++) { from_x[y][x] = x; from_y[y][x] = y; } }
    add_tile(); add_tile();
    anim_start = millis();
}

/* d: 0 left 1 right 2 up 3 down -> 1 if anything moved */
static int slide(int d)
{
    int line, i, moved = 0, save[N][N], save_score = score;
    memcpy(save, grid, sizeof grid);
    memset(merged, 0, sizeof merged); memset(born, 0, sizeof born);
    for (line = 0; line < N; line++) {
        int cx[N], cy[N], val[N], sx[N], sy[N], n = 0, out = 0;
        for (i = 0; i < N; i++) {                         /* the line, in the direction of travel */
            int k = (d == 1 || d == 3) ? N - 1 - i : i;
            cx[i] = (d < 2) ? k : line;
            cy[i] = (d < 2) ? line : k;
        }
        for (i = 0; i < N; i++)
            if (grid[cy[i]][cx[i]]) { val[n] = grid[cy[i]][cx[i]]; sx[n] = cx[i]; sy[n] = cy[i]; n++; }
        for (i = 0; i < N; i++) grid[cy[i]][cx[i]] = 0;
        for (i = 0; i < n; i++) {
            int tx = cx[out], ty = cy[out];
            if (i + 1 < n && val[i] == val[i + 1]) {
                grid[ty][tx] = val[i] * 2;
                score += val[i] * 2;
                merged[ty][tx] = 1;
                from_x[ty][tx] = sx[i + 1]; from_y[ty][tx] = sy[i + 1];   /* the one further back slides in */
                if (val[i] * 2 == 2048 && !won) won = 1;
                i++;
            } else {
                grid[ty][tx] = val[i];
                from_x[ty][tx] = sx[i]; from_y[ty][tx] = sy[i];
            }
            if (tx != sx[i] || ty != sy[i] || merged[ty][tx]) moved = 1;
            out++;
        }
    }
    if (!moved) { memcpy(grid, save, sizeof grid); score = save_score; return 0; }
    memcpy(undo_grid, save, sizeof grid);
    undo_score = save_score;
    can_undo = 1;
    add_tile();
    if (score > best) { best = score; gui_cfg_set("2048", best); }
    if (!moves_left()) over = 1;
    anim_start = millis();
    return 1;
}

static void tile_colors(int v, unsigned *bg, unsigned *fg)
{
    static const unsigned bgs[12] = {
        RGB(238, 228, 218), RGB(237, 224, 200), RGB(242, 177, 121), RGB(245, 149, 99),
        RGB(246, 124, 95), RGB(246, 94, 59), RGB(237, 207, 114), RGB(237, 204, 97),
        RGB(237, 200, 80), RGB(237, 197, 63), RGB(237, 194, 46), RGB(60, 58, 50)
    };
    int i = 0;
    while ((1 << (i + 1)) < v && i < 11) i++;
    *bg = bgs[i];
    *fg = v <= 4 ? C_DARK : C_LIGHT;
}
static void draw_tile(int px, int py, int v, int grow)       /* grow: 0-256, how big */
{
    unsigned bg, fg;
    char t[12];
    int size = TILE * grow / 256, k, tw;
    if (size < 4) return;
    tile_colors(v, &bg, &fg);
    gui_round(px + (TILE - size) / 2, py + (TILE - size) / 2, size, size, 6, bg);
    if (grow < 200) return;
    gui_num(t, v);
    k = strlen(t) <= 2 ? 4 : strlen(t) == 3 ? 3 : 2;
    tw = gui_text_w(t, k);
    gui_text(px + (TILE - tw) / 2, py + (TILE - 16 * k) / 2, t, fg, k);
}
static void box(int x, int y, int w, const char *label, int v)
{
    char n[12];
    gui_round(x, y, w, 52, 4, C_BOARD);
    gui_text_c(x + w / 2, y + 6, label, RGB(238, 228, 218), 1);
    gui_text_c(x + w / 2, y + 26, gui_num(n, v), RGB(255, 255, 255), 1);
}
static void draw(void)
{
    int x, y, t = millis() - anim_start;
    int p = t >= ANIM_MS ? 256 : t * 256 / ANIM_MS;          /* how far the slide is */
    gui_fill(0, 0, W, H, C_BG);
    gui_text(PAD, 20, "2048", C_DARK, 4);
    gui_text(PAD, 88, "Join the tiles, get to 2048!", C_DARK, 1);
    box(W - PAD - 210, 18, 100, "SCORE", score);
    box(W - PAD - 100, 18, 100, "BEST", best);
    gui_round(PAD, TOP, BOARD, BOARD, 8, C_BOARD);
    for (y = 0; y < N; y++)
        for (x = 0; x < N; x++)
            gui_round(PAD + GAP + x * (TILE + GAP), TOP + GAP + y * (TILE + GAP), TILE, TILE, 6, C_EMPTY);
    for (y = 0; y < N; y++)
        for (x = 0; x < N; x++) {
            int v = grid[y][x], tx, ty, fx, fy, grow = 256;
            if (!v) continue;
            tx = PAD + GAP + x * (TILE + GAP);
            ty = TOP + GAP + y * (TILE + GAP);
            fx = PAD + GAP + from_x[y][x] * (TILE + GAP);
            fy = TOP + GAP + from_y[y][x] * (TILE + GAP);
            if (born[y][x]) { if (p < 256) grow = p; }
            else if (p < 256) {
                /* on its way: the old value while sliding, the new one once there */
                draw_tile(fx + (tx - fx) * p / 256, fy + (ty - fy) * p / 256, merged[y][x] ? v / 2 : v, 256);
                continue;
            } else if (merged[y][x] && t < ANIM_MS * 2) grow = 256 + (ANIM_MS * 2 - t) * 40 / ANIM_MS;
            draw_tile(tx, ty, v, grow > 256 ? 256 : grow);
        }
    gui_text(PAD, H - 26, "Arrows: slide   U: undo   N: new game   Esc: quit", C_DARK, 1);
    if ((won && !kept_on) || over) {
        unsigned veil = over ? RGB(238, 228, 218) : RGB(237, 194, 46);
        int j;
        for (j = 0; j < BOARD; j++)                            /* a see-through veil */
            for (x = 0; x < BOARD; x++) {
                unsigned *q = g_frame + (TOP + j) * W + PAD + x;
                *q = gui_mix(*q, veil, 150);
            }
        gui_text_c(W / 2, TOP + BOARD / 2 - 40, over ? "Game over!" : "You win!", over ? C_DARK : C_LIGHT, 3);
        gui_text_c(W / 2, TOP + BOARD / 2 + 20, over ? "N: try again   U: undo" : "Enter: keep going   N: new game",
                   over ? C_DARK : C_LIGHT, 1);
    }
    gui_show();
}

int main(void)
{
    int m[4];
    if (gui_open(W, H) < 0) { puts("2048: needs a 532x662 picture in 32 bits\n"); return 1; }
    seed = millis();
    best = gui_cfg_get("2048", 0);
    start();
    for (;;) {
        int k, dirty = 0;
        while ((k = pollkey())) {
            int c = k & 0xFF, sc = (k >> 8) & 0xFF, d = -1;
            if (sc == KEY_ESC) return 0;
            if (c == 'n' || c == 'N') { start(); dirty = 1; continue; }
            if ((c == 'u' || c == 'U' || c == 8) && can_undo) {
                memcpy(grid, undo_grid, sizeof grid);
                score = undo_score; can_undo = 0; over = 0;
                memset(merged, 0, sizeof merged); memset(born, 0, sizeof born);
                anim_start = millis() - ANIM_MS * 2;
                dirty = 1;
                continue;
            }
            if (won && !kept_on) { if (c == '\r') { kept_on = 1; dirty = 1; } continue; }
            if (over) continue;
            if (sc == KEY_LEFT || c == 'a' || c == 'A') d = 0;
            else if (sc == KEY_RIGHT || c == 'd' || c == 'D') d = 1;
            else if (sc == KEY_UP || c == 'w' || c == 'W') d = 2;
            else if (sc == KEY_DOWN || c == 's' || c == 'S') d = 3;
            if (d >= 0 && slide(d)) dirty = 1;
        }
        mouse(m);
        if (dirty || (int)(millis() - anim_start) < ANIM_MS * 2 + 30) draw();
        sleep_ms(12);
    }
    return 0;
}
