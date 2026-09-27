/* snake.c - LexOS Snake, in a window.
 *
 *   run snake.app
 *
 * Arrows or WASD steer (the first one starts it); each apple makes the snake longer and a little
 * faster. P pauses, Esc quits. The walls and the snake's own tail are
 * the end - Space (or a click) starts again. The best score is kept
 * (/SYSTEM/APPS.CFG, "snake="). */
#include "gui.h"

#define COLS 24
#define ROWS 18
#define CELL 20
#define TOP 44
#define W (COLS * CELL)
#define H (TOP + ROWS * CELL)
#define MAXLEN (COLS * ROWS)

#define C_BG1   RGB(170, 215, 81)
#define C_BG2   RGB(162, 209, 73)
#define C_BAR   RGB(74, 117, 44)
#define C_HEAD  RGB(66, 103, 210)
#define C_BODY  RGB(78, 124, 246)
#define C_APPLE RGB(231, 71, 29)
#define C_LEAF  RGB(64, 140, 40)
#define C_WHITE RGB(255, 255, 255)

static int sx[MAXLEN], sy[MAXLEN], len;          /* [0] is the head */
static int dir, next_dir[4], queued;              /* 0 right 1 down 2 left 3 up */
static int ax, ay, score, best, dead, paused, grow, waiting;
static unsigned seed;

static unsigned rnd(void) { seed = seed * 1103515245 + 12345; return seed >> 16; }

static int on_snake(int x, int y, int from)
{
    int i;
    for (i = from; i < len; i++) if (sx[i] == x && sy[i] == y) return 1;
    return 0;
}
static void place_apple(void)
{
    do { ax = rnd() % COLS; ay = rnd() % ROWS; } while (on_snake(ax, ay, 0));
}
static void start(void)
{
    int i;
    len = 4;
    for (i = 0; i < len; i++) { sx[i] = 6 - i; sy[i] = ROWS / 2; }
    dir = 0; queued = 0; score = 0; dead = 0; paused = 0; grow = 0; waiting = 1;
    place_apple();
}

static void cell(int x, int y, int inset, unsigned c)
{
    gui_round(x * CELL + inset, TOP + y * CELL + inset, CELL - 2 * inset, CELL - 2 * inset, 4, c);
}
static void draw(void)
{
    int x, y, i;
    char t[40], n[12];
    gui_fill(0, 0, W, TOP, C_BAR);
    for (y = 0; y < ROWS; y++)
        for (x = 0; x < COLS; x++)
            gui_fill(x * CELL, TOP + y * CELL, CELL, CELL, (x + y) & 1 ? C_BG2 : C_BG1);
    /* the apple: a round one, a leaf on top */
    gui_round(ax * CELL + 3, TOP + ay * CELL + 4, CELL - 6, CELL - 6, 6, C_APPLE);
    gui_fill(ax * CELL + CELL / 2, TOP + ay * CELL + 1, 2, 4, C_LEAF);
    gui_fill(ax * CELL + CELL / 2 + 2, TOP + ay * CELL + 2, 4, 2, C_LEAF);
    for (i = len - 1; i >= 0; i--) {
        cell(sx[i], sy[i], i ? 2 : 1, i ? C_BODY : C_HEAD);
        if (i && i < len) {                       /* joined to the one before */
            int px = sx[i - 1], py = sy[i - 1];
            int lx = (px < sx[i] ? px : sx[i]), ly = (py < sy[i] ? py : sy[i]);
            if (px != sx[i]) gui_fill(lx * CELL + CELL / 2, TOP + ly * CELL + 2, CELL, CELL - 4, C_BODY);
            else gui_fill(lx * CELL + 2, TOP + ly * CELL + CELL / 2, CELL - 4, CELL, C_BODY);
        }
    }
    {                                              /* eyes, looking ahead */
        int hx = sx[0] * CELL, hy = TOP + sy[0] * CELL;
        int ex[4][4] = { {12, 5, 12, 12}, {5, 12, 12, 12}, {4, 5, 4, 12}, {5, 4, 12, 4} };
        gui_fill(hx + ex[dir][0], hy + ex[dir][1], 4, 4, C_WHITE);
        gui_fill(hx + ex[dir][2], hy + ex[dir][3], 4, 4, C_WHITE);
    }
    /* the bar: an apple, the score; the best on the right */
    gui_round(12, 12, 18, 18, 6, C_APPLE);
    gui_text(38, 14, gui_num(n, score), C_WHITE, 1);
    strcpy(t, "Best ");
    gui_cat(t, gui_num(n, best));
    gui_text(W - 12 - gui_text_w(t, 1), 14, t, RGB(255, 230, 120), 1);
    gui_text_c(W / 2, 14, waiting ? "An arrow to start" : paused ? "Paused - P" : "P pause  Esc quit", RGB(210, 230, 190), 1);
    if (dead) {
        gui_round(W / 2 - 150, TOP + 110, 300, 120, 8, RGB(40, 60, 30));
        gui_text_c(W / 2, TOP + 126, "Game over", C_WHITE, 2);
        strcpy(t, "Score ");
        gui_cat(t, gui_num(n, score));
        if (score && score >= best) gui_cat(t, " - a new best!");
        gui_text_c(W / 2, TOP + 170, t, RGB(255, 230, 120), 1);
        gui_text_c(W / 2, TOP + 196, "Space or a click: again", RGB(200, 220, 190), 1);
    }
    gui_show();
}

static void steer(int d)
{
    int last = queued ? next_dir[queued - 1] : dir;
    if (waiting && d == 2) return;                  /* (it faces right) */
    waiting = 0;
    if (queued >= 3 || d == last || (d + 2) % 4 == last) return;   /* no turning back */
    next_dir[queued++] = d;
}

static void step(void)
{
    static const int dx[4] = { 1, 0, -1, 0 }, dy[4] = { 0, 1, 0, -1 };
    int nx, ny, i;
    if (queued) { dir = next_dir[0]; for (i = 1; i < queued; i++) next_dir[i - 1] = next_dir[i]; queued--; }
    nx = sx[0] + dx[dir];
    ny = sy[0] + dy[dir];
    if (nx < 0 || ny < 0 || nx >= COLS || ny >= ROWS || (on_snake(nx, ny, 0) && !(nx == sx[len - 1] && ny == sy[len - 1] && !grow))) {
        dead = 1;
        beep(160, 250);
        if (score > best) { best = score; gui_cfg_set("snake", best); }
        return;
    }
    if (grow) { if (len < MAXLEN) len++; grow--; }
    for (i = len - 1; i > 0; i--) { sx[i] = sx[i - 1]; sy[i] = sy[i - 1]; }
    sx[0] = nx; sy[0] = ny;
    if (nx == ax && ny == ay) {
        score += 10;
        grow += 2;
        beep(880, 25);
        if (len + grow >= MAXLEN) { dead = 1; return; }
        place_apple();
    }
}

int main(void)
{
    unsigned next;
    int m[4], was = 0;
    if (gui_open(W, H) < 0) { puts("snake: needs a 480x404 picture in 32 bits\n"); return 1; }
    seed = millis();
    best = gui_cfg_get("snake", 0);
    start();
    next = millis();
    for (;;) {
        int k;
        while ((k = pollkey())) {
            int c = k & 0xFF, sc = (k >> 8) & 0xFF;
            if (sc == KEY_ESC) return 0;
            if (dead) { if (c == ' ' || c == '\r') start(); continue; }
            if (c == 'p' || c == 'P') paused = !paused;
            else if (sc == KEY_RIGHT || c == 'd' || c == 'D') steer(0);
            else if (sc == KEY_DOWN || c == 's' || c == 'S') steer(1);
            else if (sc == KEY_LEFT || c == 'a' || c == 'A') steer(2);
            else if (sc == KEY_UP || c == 'w' || c == 'W') steer(3);
        }
        if (mouse(m)) {
            if ((m[2] & 1) && !was && dead) start();
            was = m[2] & 1;
        }
        if (!dead && !paused && !waiting) step();
        draw();
        /* 130ms a step at first, down to 60 */
        next += 130 - (score / 10 * 3 > 70 ? 70 : score / 10 * 3);
        sleep_until(next);
        if ((int)(millis() - next) > 200) next = millis();
    }
    return 0;
}
