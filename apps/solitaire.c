/* solitaire.c - Klondike ("Косынка"), in a window.
 *
 *   run solitaire.app
 *
 * The cards are carried with the mouse: from the waste, a foundation or
 * any face-up card of a column (and all below it), onto a column (one
 * less, the other color; a King on an empty one) or a foundation (the
 * same suit, one more; an Ace to begin). A click on the stock turns a
 * card over (three with "Draw 3"), on the empty stock the waste goes
 * back. A double click sends a card home to its foundation; the right
 * button (or A) sends all it can. U or Ctrl+Z undoes, F2 or N deals
 * again, D switches between drawing one and three, Esc quits. The best
 * time is kept (/SYSTEM/APPS.CFG, "solitaire="). */
#include "gui.h"

#define W 600
#define H 580
#define CW 64                       /* a card */
#define CH 88
#define GAP 16
#define COLX(i) (GAP + (i) * (CW + 16))
#define TOP_Y 44
#define TAB_Y 150
#define BAR_H 32

#define C_TABLE  RGB(24, 110, 70)
#define C_TABLE2 RGB(20, 96, 60)
#define C_BAR    RGB(18, 70, 46)
#define C_SLOT   RGB(40, 130, 88)
#define C_CARD   RGB(252, 252, 250)
#define C_EDGE   RGB(120, 130, 120)
#define C_RED    RGB(210, 40, 40)
#define C_BLACK  RGB(28, 30, 36)
#define C_BACK   RGB(40, 80, 170)
#define C_BACK2  RGB(70, 110, 200)
#define C_LIT    RGB(255, 214, 70)

/* piles: 0 the stock, 1 the waste, 2-5 the foundations, 6-12 the columns */
#define STOCK 0
#define WASTE 1
#define FOUND 2
#define TAB   6
#define NP    13
struct pile { int n; unsigned char c[52], up[52]; };
static struct pile p[NP];

/* a card: rank 0-12 (Ace..King) * 4 + suit (0 spades, 1 hearts, 2 diamonds, 3 clubs) */
#define RANK(c) ((c) >> 2)
#define SUIT(c) ((c) & 3)
#define RED(c)  (SUIT(c) == 1 || SUIT(c) == 2)

#define UNDO_MAX 64
static struct pile undo_st[UNDO_MAX][NP];
static int undo_n, draw3, moves, won, best, started;
static unsigned t_start, t_end, seed;
static int btn_hot = -1;

/* carrying: from which pile, from which card, where the pointer holds it */
static int drag, drag_from, drag_i, drag_dx, drag_dy, drag_x, drag_y, drag_moved, press_x, press_y;
static int last_pile = -1, last_i = -1;
static unsigned last_click;

static unsigned rnd(void) { seed = seed * 1103515245 + 12345; return seed >> 16; }

/* ---- the suits: 9x9 pictures ---- */
static const unsigned short suit_bits[4][9] = {
    { 0x010, 0x038, 0x07C, 0x0FE, 0x1FF, 0x1FF, 0x0D6, 0x010, 0x038 },   /* spade */
    { 0x0C6, 0x1EF, 0x1FF, 0x1FF, 0x0FE, 0x07C, 0x038, 0x010, 0x000 },   /* heart */
    { 0x010, 0x038, 0x07C, 0x0FE, 0x1FF, 0x0FE, 0x07C, 0x038, 0x010 },   /* diamond */
    { 0x038, 0x07C, 0x07C, 0x1BB, 0x1FF, 0x1FF, 0x1BB, 0x010, 0x038 },   /* club */
};
static void draw_suit(int x, int y, int s, int k, unsigned c)
{
    int r, b;
    for (r = 0; r < 9; r++)
        for (b = 0; b < 9; b++)
            if (suit_bits[s][r] & (0x100 >> b)) gui_fill(x + b * k, y + r * k, k, k, c);
}
static const char *rank_name[13] = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" };

static void draw_card(int x, int y, int c, int up, int lit)
{
    gui_round(x, y, CW, CH, 4, lit ? C_LIT : C_EDGE);
    if (!up) {                                       /* its back */
        int i, j;
        gui_round(x + 1, y + 1, CW - 2, CH - 2, 4, C_CARD);
        gui_round(x + 4, y + 4, CW - 8, CH - 8, 3, C_BACK);
        for (j = 0; j < CH - 12; j += 6)
            for (i = (j / 6) & 1 ? 3 : 0; i < CW - 12; i += 6) gui_fill(x + 6 + i, y + 6 + j, 2, 2, C_BACK2);
        return;
    }
    {
        unsigned ink = RED(c) ? C_RED : C_BLACK;
        gui_round(x + 1, y + 1, CW - 2, CH - 2, 4, C_CARD);
        gui_text(x + 5, y + 3, rank_name[RANK(c)], ink, 1);
        draw_suit(x + 5, y + 21, SUIT(c), 1, ink);
        gui_text(x + CW - 5 - gui_text_w(rank_name[RANK(c)], 1), y + 3, rank_name[RANK(c)], ink, 1);
        if (RANK(c) >= 10) {                         /* a face: its letter big */
            gui_round(x + 16, y + 30, CW - 32, CH - 38, 3, RED(c) ? RGB(252, 226, 220) : RGB(226, 232, 244));
            gui_text_c(x + CW / 2, y + 40, rank_name[RANK(c)], ink, 2);
            draw_suit(x + CW / 2 - 9, y + 60, SUIT(c), 2, ink);
        } else draw_suit(x + CW / 2 - 13, y + 38, SUIT(c), 3, ink);
    }
}
static void draw_slot(int x, int y, const char *t)
{
    gui_round(x, y, CW, CH, 4, C_SLOT);
    gui_round(x + 2, y + 2, CW - 4, CH - 4, 4, C_TABLE);
    if (t) gui_text_c(x + CW / 2, y + CH / 2 - 8, t, C_SLOT, 1);
}

/* ---- where things are ---- */
static int pile_x(int i)
{
    if (i == STOCK) return COLX(0);
    if (i == WASTE) return COLX(1);
    if (i < TAB) return COLX(3 + i - FOUND);
    return COLX(i - TAB);
}
/* a column's cards: face-down ones closer; squeezed to fit */
static int step_down, step_up;
static void steps(int i)
{
    int down = 0, upn = 0, k, room = H - BAR_H - 8 - TAB_Y - CH;
    for (k = 0; k < p[i].n; k++) { if (p[i].up[k]) upn++; else down++; }
    step_down = 10; step_up = 24;
    while (step_up > 12 && down * step_down + (upn ? upn - 1 : 0) * step_up > room) step_up--;
    while (step_down > 3 && down * step_down + (upn ? upn - 1 : 0) * step_up > room) step_down--;
}
static int card_y(int i, int k)
{
    int j, y = TAB_Y;
    if (i < TAB) return TOP_Y;
    steps(i);
    for (j = 0; j < k; j++) y += p[i].up[j] ? step_up : step_down;
    return y;
}
/* the waste's fan (draw 3): the last three a little apart */
static int waste_x(int k)
{
    int n = p[WASTE].n, from = n > 3 ? n - 3 : 0;
    if (!draw3 || k < from) return COLX(1);
    return COLX(1) + (k - from) * 14;
}

/* (mx, my) -> which pile, which card of it (-1: the pile itself, empty) */
static int hit(int mx, int my, int *ki)
{
    int i, k;
    for (i = 0; i < NP; i++) {
        int x = pile_x(i);
        if (i >= TAB) {
            for (k = p[i].n - 1; k >= 0; k--) {
                int y = card_y(i, k);
                if (gui_in(mx, my, x, y, CW, CH)) { *ki = k; return i; }
            }
            if (!p[i].n && gui_in(mx, my, x, TAB_Y, CW, CH)) { *ki = -1; return i; }
        } else if (i == WASTE) {
            if (p[i].n && gui_in(mx, my, waste_x(p[i].n - 1), TOP_Y, CW, CH)) { *ki = p[i].n - 1; return i; }
        } else if (gui_in(mx, my, x, TOP_Y, CW, CH)) { *ki = p[i].n - 1; return i; }
    }
    return -1;
}

/* ---- the game ---- */
static void save_undo(void)
{
    if (undo_n == UNDO_MAX) { memmove(undo_st[0], undo_st[1], sizeof undo_st[0] * (UNDO_MAX - 1)); undo_n--; }
    memcpy(undo_st[undo_n++], p, sizeof p);
}
static void undo(void)
{
    if (!undo_n || won) return;
    memcpy(p, undo_st[--undo_n], sizeof p);
    moves++;
}
static void deal(void)
{
    int d[52], i, j, k = 0;
    memset(p, 0, sizeof p);
    for (i = 0; i < 52; i++) d[i] = i;
    for (i = 51; i > 0; i--) { j = rnd() % (i + 1); k = d[i]; d[i] = d[j]; d[j] = k; }
    k = 0;
    for (i = 0; i < 7; i++)
        for (j = 0; j <= i; j++) {
            struct pile *t = &p[TAB + i];
            t->c[t->n] = d[k++];
            t->up[t->n] = j == i;
            t->n++;
        }
    while (k < 52) { p[STOCK].c[p[STOCK].n] = d[k++]; p[STOCK].up[p[STOCK].n++] = 0; }
    undo_n = 0; moves = 0; won = 0; started = 0; drag = 0;
}
static void flip_tops(void)
{
    int i;
    for (i = TAB; i < NP; i++) if (p[i].n && !p[i].up[p[i].n - 1]) p[i].up[p[i].n - 1] = 1;
}
static void check_won(void)
{
    int i, n = 0;
    for (i = FOUND; i < TAB; i++) n += p[i].n;
    if (n == 52 && !won) {
        int secs;
        won = 1;
        t_end = millis();
        secs = (t_end - t_start) / 1000;
        if (!best || secs < best) { best = secs; gui_cfg_set("solitaire", secs); }
        beep(880, 80); beep(1175, 80); beep(1568, 160);
    }
}
static void begin(void) { if (!started) { started = 1; t_start = millis(); } }
/* can card c (with its run) go onto pile t? */
static int fits(int c, int count, int t)
{
    struct pile *q = &p[t];
    if (t >= FOUND && t < TAB) {
        if (count != 1) return 0;
        if (!q->n) return RANK(c) == 0 && SUIT(c) == t - FOUND;
        return SUIT(q->c[q->n - 1]) == SUIT(c) && RANK(q->c[q->n - 1]) + 1 == RANK(c);
    }
    if (t >= TAB) {
        if (!q->n) return RANK(c) == 12;
        if (!q->up[q->n - 1]) return 0;
        return RED(q->c[q->n - 1]) != RED(c) && RANK(q->c[q->n - 1]) == RANK(c) + 1;
    }
    return 0;
}
/* the cards from pile f's k-th on, onto pile t (if they fit) -> 1 */
static int move(int f, int k, int t)
{
    int n = p[f].n - k, j;
    /* an Ace goes to its own suit's place, whichever one it's dropped on */
    if (t >= FOUND && t < TAB && n == 1 && RANK(p[f].c[k]) == 0) t = FOUND + SUIT(p[f].c[k]);
    if (f == t || n <= 0 || !p[f].up[k] || !fits(p[f].c[k], n, t)) return 0;
    save_undo();
    begin();
    for (j = 0; j < n; j++) {
        p[t].c[p[t].n] = p[f].c[k + j];
        p[t].up[p[t].n++] = 1;
    }
    p[f].n = k;
    flip_tops();
    moves++;
    check_won();
    return 1;
}
static void turn_stock(void)
{
    int j;
    save_undo();
    begin();
    if (!p[STOCK].n) {                               /* the waste back */
        while (p[WASTE].n) {
            p[STOCK].c[p[STOCK].n] = p[WASTE].c[--p[WASTE].n];
            p[STOCK].up[p[STOCK].n++] = 0;
        }
    } else
        for (j = 0; j < (draw3 ? 3 : 1) && p[STOCK].n; j++) {
            p[WASTE].c[p[WASTE].n] = p[STOCK].c[--p[STOCK].n];
            p[WASTE].up[p[WASTE].n++] = 1;
        }
    moves++;
}
/* pile f's top card home to a foundation -> 1 */
static int home(int f)
{
    int t;
    if (!p[f].n || (f >= FOUND && f < TAB)) return 0;
    for (t = FOUND; t < TAB; t++) if (move(f, p[f].n - 1, t)) return 1;
    return 0;
}
static void all_home(void)
{
    int again = 1, i;
    while (again) {
        again = 0;
        for (i = WASTE; i < NP; i++) if (i != STOCK && home(i)) again = 1;
    }
}

/* ---- drawing ---- */
static const char *btn_label[3] = { "New", "Undo", "Draw 1" };
static int btn_x(int i) { return 8 + i * 84; }
static void draw(void)
{
    int i, k, y;
    char t[48], n[12];
    unsigned secs = !started ? 0 : won ? (t_end - t_start) / 1000 : (millis() - t_start) / 1000;
    gui_fill(0, 0, W, H, C_TABLE);
    for (y = BAR_H; y < H; y += 4) gui_fill(0, y, W, 1, C_TABLE2);
    /* the bar */
    gui_fill(0, 0, W, BAR_H, C_BAR);
    for (i = 0; i < 3; i++) gui_button(btn_x(i), 4, 76, 24, i == 2 ? (draw3 ? "Draw 3" : "Draw 1") : btn_label[i], btn_hot == i);
    strcpy(t, "Moves ");
    gui_cat(t, gui_num(n, moves));
    gui_cat(t, "   ");
    gui_cat(t, gui_num(n, secs / 60));
    gui_cat(t, secs % 60 < 10 ? ":0" : ":");
    gui_cat(t, gui_num(n, secs % 60));
    if (best) { gui_cat(t, "   Best "); gui_cat(t, gui_num(n, best / 60)); gui_cat(t, best % 60 < 10 ? ":0" : ":"); gui_cat(t, gui_num(n, best % 60)); }
    gui_text(W - 8 - gui_text_w(t, 1), 8, t, RGB(210, 236, 220), 1);
    /* the stock, the waste, the foundations */
    if (p[STOCK].n) draw_card(COLX(0), TOP_Y, 0, 0, 0);
    else draw_slot(COLX(0), TOP_Y, p[WASTE].n ? "again" : 0);
    if (!p[WASTE].n) draw_slot(COLX(1), TOP_Y, 0);
    for (k = p[WASTE].n > 3 ? p[WASTE].n - 3 : 0; k < p[WASTE].n; k++) {
        if (drag && drag_from == WASTE && k >= drag_i) break;
        draw_card(waste_x(k), TOP_Y, p[WASTE].c[k], 1, 0);
    }
    for (i = FOUND; i < TAB; i++) {
        struct pile *q = &p[i];
        int top = q->n - (drag && drag_from == i ? 1 : 0);
        if (top > 0) draw_card(pile_x(i), TOP_Y, q->c[top - 1], 1, 0);
        else { draw_slot(pile_x(i), TOP_Y, 0); draw_suit(pile_x(i) + CW / 2 - 13, TOP_Y + CH / 2 - 13, i - FOUND, 3, C_SLOT); }
    }
    /* the columns */
    for (i = TAB; i < NP; i++) {
        int end = p[i].n;
        if (drag && drag_from == i) end = drag_i;
        if (!p[i].n) draw_slot(pile_x(i), TAB_Y, "K");
        for (k = 0; k < end; k++) draw_card(pile_x(i), card_y(i, k), p[i].c[k], p[i].up[k], 0);
    }
    /* what's carried, over everything */
    if (drag) {
        int f = drag_from;
        for (k = drag_i; k < p[f].n; k++)
            draw_card(drag_x - drag_dx, drag_y - drag_dy + (k - drag_i) * 24, p[f].c[k], 1, 1);
    }
    if (won) {
        gui_round(W / 2 - 150, H / 2 - 44, 300, 88, 8, RGB(18, 50, 34));
        gui_text_c(W / 2, H / 2 - 32, "You won!", C_LIT, 2);
        strcpy(t, "in ");
        gui_cat(t, gui_num(n, secs / 60));
        gui_cat(t, secs % 60 < 10 ? ":0" : ":");
        gui_cat(t, gui_num(n, secs % 60));
        gui_cat(t, ", ");
        gui_cat(t, gui_num(n, moves));
        gui_cat(t, " moves - F2: again");
        gui_text_c(W / 2, H / 2 + 10, t, RGB(210, 236, 220), 1);
    }
    gui_show();
}

int main(void)
{
    int m[4], was = 0, last_secs = -1;
    seed = millis();
    best = gui_cfg_get("solitaire", 0);
    draw3 = gui_cfg_get("solitaire3", 0);
    if (gui_open(W, H) < 0) { puts("solitaire: needs a window in 32 bits\n"); return 1; }
    keymode(1);
    deal();
    draw();
    for (;;) {
        int k, changed = 0;
        while ((k = pollkey())) {
            int c = k & 0xFF, sc = (k >> 8) & 0xFF;
            if (sc == KEY_ESC) return 0;
            if (sc == 0x3C || c == 'n' || c == 'N') deal();                          /* F2 */
            else if (c == 'u' || c == 'U' || (c == 26 && gui_ctrl(c, sc))) undo();   /* Ctrl+Z */
            else if (c == 'a' || c == 'A') all_home();
            else if (c == 'd' || c == 'D') { draw3 ^= 1; gui_cfg_set("solitaire3", draw3); deal(); }
            changed = 1;
        }
        if (mouse(m) || drag) {
            int mx = m[0], my = m[1], b = m[2], h = -1, i;
            for (i = 0; i < 3; i++) if (gui_in(mx, my, btn_x(i), 4, 76, 24)) h = i;
            if (h != btn_hot) { btn_hot = h; changed = 1; }
            if ((b & 1) && !was) {                                   /* pressed */
                int ki = -1, pi = hit(mx, my, &ki);
                changed = 1;
                if (h == 0) deal();
                else if (h == 1) undo();
                else if (h == 2) { draw3 ^= 1; gui_cfg_set("solitaire3", draw3); deal(); }
                else if (!won && pi == STOCK) turn_stock();
                else if (!won && pi >= 0 && ki >= 0 && p[pi].up[ki]) {
                    unsigned now = millis();
                    if (pi == last_pile && ki == last_i && ki == p[pi].n - 1 && now - last_click < 450) {
                        home(pi);                                    /* a double click */
                        last_pile = -1;
                    } else {
                        int cx = pi == WASTE ? waste_x(ki) : pile_x(pi);
                        drag = 1; drag_from = pi; drag_i = ki; drag_moved = 0;
                        drag_dx = mx - cx; drag_dy = my - card_y(pi, ki);
                        drag_x = mx; drag_y = my; press_x = mx; press_y = my;
                        last_pile = pi; last_i = ki; last_click = now;
                    }
                }
            } else if ((b & 1) && drag) {                            /* carried */
                if (mx != drag_x || my != drag_y) {
                    drag_x = mx; drag_y = my; changed = 1;
                    if ((mx - press_x) * (mx - press_x) + (my - press_y) * (my - press_y) > 16) drag_moved = 1;
                }
            } else if (!(b & 1) && drag) {                           /* let go */
                int best_t = -1, best_o = 0, t;
                int cx = drag_x - drag_dx, cy = drag_y - drag_dy;
                drag = 0; changed = 1;
                if (drag_moved)
                    for (t = FOUND; t < NP; t++) {                   /* the pile it covers most */
                        int x = pile_x(t), y = t >= TAB ? card_y(t, p[t].n ? p[t].n - 1 : 0) : TOP_Y;
                        int ox = (cx < x ? cx + CW - x : x + CW - cx), oy = (cy < y ? cy + CH - y : y + CH - cy);
                        if (t >= TAB) oy = cy + CH > y ? CH : 0;     /* (a column: anywhere down it) */
                        if (ox > 0 && oy > 0 && ox * oy > best_o && fits(p[drag_from].c[drag_i], p[drag_from].n - drag_i, t)) { best_o = ox * oy; best_t = t; }
                    }
                if (best_t >= 0) move(drag_from, drag_i, best_t);
            }
            if ((b & 2) && !(was & 2) && !won) { all_home(); changed = 1; }   /* the right button */
            was = b;
        } else if (btn_hot >= 0) { btn_hot = -1; changed = 1; was = 0; }
        if (started && !won && (int)((millis() - t_start) / 1000) != last_secs) { last_secs = (millis() - t_start) / 1000; changed = 1; }
        if (changed) draw();
        sleep_ms(15);
    }
    return 0;
}
