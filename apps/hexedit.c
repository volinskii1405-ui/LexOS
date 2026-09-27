/* hexedit.c - LexOS Hex Editor: any file's bytes, in a window.
 *
 *   run hexedit.app [file]      (Files: a file's menu, "Open in Hex editor")
 *
 * Each row: where it is in the file, 16 bytes in hex, the same 16 as
 * letters. Typing hex digits changes the byte under the cursor (a digit
 * a half); Tab moves to the letters' side, where typing puts letters.
 * Insert switches between writing over and putting new bytes in;
 * Delete / Backspace take bytes out. Shift + arrows (or the mouse)
 * select; the status line shows the byte (and a selection's size).
 *
 *   Ctrl+O open    Ctrl+S save    Ctrl+Shift+S save as
 *   Ctrl+Z undo    Ctrl+Y redo    Ctrl+F find (hex: "DE AD", or text)
 *   F3 the next one               Ctrl+G go to an offset (hex)
 *   PgUp / PgDn, Home / End (of the row), Ctrl+Home / Ctrl+End
 *   Esc quits (asking first if there are changes) */
#include "gui.h"

#define W 792
#define H 584
#define BAR_H 34
#define HEAD_Y (BAR_H + 4)
#define ROW_Y (HEAD_Y + 20)
#define LINE_H 18
#define STATUS_H 24
#define ROWS ((H - ROW_Y - STATUS_H - 4) / LINE_H)
#define OFF_X 12
#define HEX_X 108
#define ASC_X (HEX_X + 16 * 24 + 18)
#define SB_X (W - 16)
#define MAXF (2 * 1024 * 1024)
#define UNDO_MAX 4096

#define C_BG     RGB(255, 255, 255)
#define C_TEXT   RGB(28, 30, 36)
#define C_GRAY   RGB(130, 136, 150)
#define C_BAR    RGB(226, 232, 242)
#define C_LINE   RGB(200, 206, 218)
#define C_SEL    RGB(184, 212, 250)
#define C_CUR    RGB(40, 90, 200)
#define C_ZERO   RGB(190, 196, 208)
#define C_CHANGED RGB(200, 60, 40)
#define C_ALT    RGB(247, 249, 252)

static unsigned char *data, *orig;               /* orig: as loaded, to mark changes */
static int size, orig_size, cap;
static char path[128];
static int cur, half, anchor = -1, top, in_text, insert_mode, dirty;
static char status[96], field[64];
static int mode;                                  /* 0 editing, 1 find, 2 go to, 3 quit? */
static unsigned char pat[32];
static int pat_n;
static int hover = -1;

/* undo: one byte each - what was there, what is */
struct edit { int pos; short kind; unsigned char was, is; int group; };
#define E_SET 0
#define E_INS 1
#define E_DEL 2
static struct edit undo_log[UNDO_MAX];
static int n_undo, n_redo_top, group;

static void say(const char *t) { strcpy(status, t); }
static int hexval(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static void hex2(char *o, int v) { const char *d = "0123456789ABCDEF"; o[0] = d[v >> 4 & 15]; o[1] = d[v & 15]; o[2] = 0; }
static void hex8(char *o, unsigned v) { int i; const char *d = "0123456789ABCDEF"; for (i = 7; i >= 0; i--) { o[i] = d[v & 15]; v >>= 4; } o[8] = 0; }

static int grow(int need)
{
    unsigned char *n;
    if (need <= cap) return 1;
    if (need > MAXF) { say("The file can't grow past 2 MB here."); return 0; }
    n = malloc(need + 65536);
    if (!n) { say("Out of memory."); return 0; }
    memcpy(n, data, size);
    free(data);
    data = n;
    cap = need + 65536;
    return 1;
}
static void log_edit(int pos, int kind, int was, int is)
{
    if (n_undo >= UNDO_MAX) { memmove(undo_log, undo_log + 1, (UNDO_MAX - 1) * sizeof undo_log[0]); n_undo--; }
    undo_log[n_undo].pos = pos; undo_log[n_undo].kind = kind;
    undo_log[n_undo].was = was; undo_log[n_undo].is = is; undo_log[n_undo].group = group;
    n_undo++;
    n_redo_top = n_undo;
    dirty = 1;
}
static void set_byte(int pos, int v)
{
    if (pos == size) {                             /* past the end: one more */
        if (!grow(size + 1)) return;
        data[size++] = v;
        log_edit(pos, E_INS, 0, v);
        return;
    }
    if (data[pos] == v) return;
    log_edit(pos, E_SET, data[pos], v);
    data[pos] = v;
}
static void ins_byte(int pos, int v)
{
    if (!grow(size + 1)) return;
    memmove(data + pos + 1, data + pos, size - pos);
    data[pos] = v;
    size++;
    log_edit(pos, E_INS, 0, v);
}
static void del_bytes(int pos, int n)
{
    int i;
    if (pos + n > size) n = size - pos;
    for (i = n - 1; i >= 0; i--) log_edit(pos + i, E_DEL, data[pos + i], 0);
    memmove(data + pos, data + pos + n, size - pos - n);
    size -= n;
}
static void undo(int redo)
{
    int g;
    if (!redo) {
        if (!n_undo) { say("Nothing to undo."); return; }
        g = undo_log[n_undo - 1].group;
        while (n_undo && undo_log[n_undo - 1].group == g) {
            struct edit *e = &undo_log[--n_undo];
            if (e->kind == E_SET) data[e->pos] = e->was;
            else if (e->kind == E_INS) { memmove(data + e->pos, data + e->pos + 1, size - e->pos - 1); size--; }
            else { memmove(data + e->pos + 1, data + e->pos, size - e->pos); data[e->pos] = e->was; size++; }
            cur = e->pos;
        }
    } else {
        if (n_undo >= n_redo_top) { say("Nothing to redo."); return; }
        g = undo_log[n_undo].group;
        while (n_undo < n_redo_top && undo_log[n_undo].group == g) {
            struct edit *e = &undo_log[n_undo++];
            if (e->kind == E_SET) data[e->pos] = e->is;
            else if (e->kind == E_INS) { memmove(data + e->pos + 1, data + e->pos, size - e->pos); data[e->pos] = e->is; size++; }
            else { memmove(data + e->pos, data + e->pos + 1, size - e->pos - 1); size--; }
            cur = e->pos;
        }
    }
    if (cur > size) cur = size;
    half = 0; anchor = -1;
    dirty = 1;
}

static void load(const char *p)
{
    int fd = open(p, O_READ), n;
    if (fd < 0) { say("Can't open it."); return; }
    n = fsize(fd);
    if (n > MAXF) { close(fd); say("Too big: 2 MB at most."); return; }
    free(data); free(orig);
    cap = n + 65536;
    data = malloc(cap);
    orig = malloc(n + 1);
    if (!data || !orig) { close(fd); say("Out of memory."); size = 0; return; }
    size = read(fd, data, n);
    if (size < 0) size = 0;
    close(fd);
    memcpy(orig, data, size);
    orig_size = size;
    strcpy(path, p);
    cur = half = top = 0; anchor = -1; dirty = 0; n_undo = n_redo_top = 0;
    status[0] = 0;
}
static void save(int as)
{
    int fd;
    if (as || !path[0]) {
        char p[128];
        strcpy(p, path[0] ? path : "/");
        if (!gui_file_dialog("Save as", p, 1, 0)) return;
        strcpy(path, p);
    }
    fd = open(path, O_WRITE);
    if (fd < 0) { say("Can't save it there."); return; }
    fwrite(fd, data, size);
    close(fd);
    free(orig);
    orig = malloc(size + 1);
    if (orig) memcpy(orig, data, size);
    orig_size = orig ? size : 0;
    dirty = 0;
    say("Saved.");
}

/* ---- find ---- */
static int parse_pattern(void)
{
    int i, v = -1, hex = 1, n = 0;
    for (i = 0; field[i]; i++) if (field[i] != ' ' && hexval(field[i]) < 0) hex = 0;
    if (hex) {
        for (i = 0; field[i] && n < 32; i++) {
            if (field[i] == ' ') continue;
            if (v < 0) v = hexval(field[i]) << 4;
            else { pat[n++] = v | hexval(field[i]); v = -1; }
        }
        if (v >= 0) hex = 0;                       /* an odd digit: as text */
    }
    if (!hex) for (n = 0; field[n] && n < 32; n++) pat[n] = field[n];
    pat_n = n;
    return n;
}
static void find_next(void)
{
    int i, k, from;
    if (!pat_n) { say("Ctrl+F: what to find."); return; }
    from = cur + 1;
    for (k = 0; k < 2; k++) {
        for (i = from; i + pat_n <= size; i++)
            if (!memcmp(data + i, pat, pat_n)) {
                cur = i; anchor = i + pat_n - 1; half = 0;
                say("Found. F3: the next one.");
                return;
            }
        from = 0;                                  /* round again from the start */
    }
    say("Not found.");
}

/* ---- where things are ---- */
static void follow(void)
{
    int row = cur / 16;
    if (row < top) top = row;
    if (row >= top + ROWS) top = row - ROWS + 1;
    if (top < 0) top = 0;
}
static int sel_a(void) { return anchor < 0 ? -1 : anchor < cur ? anchor : cur; }
static int sel_b(void) { return anchor < 0 ? -1 : anchor < cur ? cur : anchor; }
/* the byte at a point (-1: none); *text = on the letters' side */
static int byte_at(int mx, int my, int *text)
{
    int r = (my - ROW_Y) / LINE_H, c = -1;
    if (my < ROW_Y || r >= ROWS) return -1;
    if (mx >= HEX_X - 3 && mx < HEX_X + 16 * 24 + 6) {        /* (a gap after 8) */
        int x = mx - HEX_X + 3;
        if (x >= 8 * 24 + 3) x -= 6;
        c = x / 24; if (c > 15) c = 15;
        *text = 0;
    }
    else if (mx >= ASC_X && mx < ASC_X + 16 * 10) { c = (mx - ASC_X) / 10; *text = 1; }
    if (c < 0) return -1;
    c += (top + r) * 16;
    return c > size ? size : c;
}

/* ---- drawing ---- */
static const char *btn_label[] = { "Open", "Save", "Save as", "Undo", "Redo", "Find", "Go to", "Insert" };
static int btn_x(int i) { int x = 8, k; for (k = 0; k < i; k++) x += gui_text_w(btn_label[k], 1) + 22; return x; }
static int btn_w(int i) { return gui_text_w(btn_label[i], 1) + 16; }
#define NBTN 8

static void draw(void)
{
    int r, c, a = sel_a(), b = sel_b(), i;
    char t[96], n[16];
    gui_fill(0, 0, W, H, C_BG);
    gui_fill(0, 0, W, BAR_H, C_BAR);
    gui_fill(0, BAR_H - 1, W, 1, C_LINE);
    for (i = 0; i < NBTN; i++) {
        int on = i == 7 && insert_mode;
        gui_round(btn_x(i), 5, btn_w(i), 24, 3, on ? RGB(40, 90, 200) : hover == i ? RGB(206, 222, 250) : RGB(248, 250, 253));
        gui_text_c(btn_x(i) + btn_w(i) / 2, 9, btn_label[i], on ? RGB(255, 255, 255) : C_TEXT, 1);
    }
    gui_text_n(btn_x(NBTN) + 8, 9, path[0] ? path : "(no file)", (W - btn_x(NBTN) - 16) / 8, C_GRAY);
    /* the column heads: 00 01 ... 0F */
    gui_text(OFF_X, HEAD_Y, "Offset", C_GRAY, 1);
    for (c = 0; c < 16; c++) { hex2(n, c); gui_text(HEX_X + c * 24 + (c >= 8 ? 6 : 0), HEAD_Y, n, C_GRAY, 1); }
    gui_text(ASC_X, HEAD_Y, "Text", C_GRAY, 1);
    gui_fill(0, ROW_Y - 3, SB_X, 1, C_LINE);
    for (r = 0; r < ROWS; r++) {
        int row = top + r, y = ROW_Y + r * LINE_H;
        if (row * 16 > size) break;
        if (row & 1) gui_fill(0, y, SB_X, LINE_H, C_ALT);
        hex8(t, row * 16);
        gui_text(OFF_X, y + 1, t, cur / 16 == row ? C_CUR : C_GRAY, 1);
        for (c = 0; c < 16; c++) {
            int p = row * 16 + c, hx = HEX_X + c * 24 + (c >= 8 ? 6 : 0), ax = ASC_X + c * 10;
            unsigned col;
            if (p > size) break;
            if (a >= 0 && p >= a && p <= b && p < size) { gui_fill(hx - 3, y, 22, LINE_H, C_SEL); gui_fill(ax, y, 10, LINE_H, C_SEL); }
            if (p == cur) {                           /* the cursor: both sides */
                gui_box(hx - 3, y, 22, LINE_H, in_text ? C_LINE : C_CUR);
                gui_box(ax, y, 10, LINE_H, in_text ? C_CUR : C_LINE);
                if (!in_text) gui_fill(hx - 1 + half * 8, y + LINE_H - 3, 8, 2, C_CUR);
            }
            if (p == size) { gui_text(hx, y + 1, "..", C_ZERO, 1); break; }
            hex2(n, data[p]);
            col = data[p] ? C_TEXT : C_ZERO;
            if (p >= orig_size || data[p] != orig[p]) col = C_CHANGED;
            gui_text(hx, y + 1, n, col, 1);
            gui_glyph(ax + 1, y + 1, data[p] >= 32 && data[p] < 127 ? data[p] : data[p] >= 128 ? data[p] : '.',
                      data[p] >= 32 && data[p] != 127 ? col : C_ZERO, 1);
        }
    }
    gui_fill(HEX_X + 8 * 24 - 1, ROW_Y - 2, 1, ROWS * LINE_H, C_LINE);
    gui_fill(ASC_X - 10, ROW_Y - 2, 1, ROWS * LINE_H, C_LINE);
    {                                              /* the scrollbar */
        int rows_all = size / 16 + 1, sh = ROWS * LINE_H;
        gui_fill(SB_X, ROW_Y - 2, 16, sh, RGB(236, 238, 242));
        if (rows_all > ROWS) {
            int th = sh * ROWS / rows_all, ty = (sh - (th < 20 ? 20 : th)) * top / (rows_all - ROWS);
            gui_round(SB_X + 3, ROW_Y - 2 + ty, 10, th < 20 ? 20 : th, 4, RGB(170, 180, 198));
        }
    }
    /* the status line */
    gui_fill(0, H - STATUS_H, W, STATUS_H, RGB(236, 238, 242));
    gui_fill(0, H - STATUS_H, W, 1, C_LINE);
    if (mode == 1 || mode == 2) {
        gui_text(8, H - STATUS_H + 4, mode == 1 ? "Find (hex or text):" : "Go to (hex):", C_TEXT, 1);
        gui_field(mode == 1 ? 170 : 110, H - STATUS_H + 1, 260, field, 1);
        gui_text(450, H - STATUS_H + 4, "Enter: go   Esc: back", C_GRAY, 1);
    } else if (mode == 3) {
        gui_text(8, H - STATUS_H + 4, "Changes aren't saved. Quit anyway? Y / N", C_CHANGED, 1);
    } else {
        strcpy(t, "Offset ");
        hex8(n, cur); gui_cat(t, n);
        if (cur < size) {
            gui_cat(t, "   Byte ");
            hex2(n, data[cur]); gui_cat(t, n);
            gui_cat(t, " = "); gui_cat(t, gui_num(n, data[cur]));
        }
        if (a >= 0) { gui_cat(t, "   Selected "); gui_cat(t, gui_num(n, b - a + 1)); }
        gui_cat(t, "   Size "); gui_cat(t, gui_num(n, size));
        if (dirty) gui_cat(t, " *");
        gui_text(8, H - STATUS_H + 4, t, C_TEXT, 1);
        gui_text(W - 8 - gui_text_w(insert_mode ? "INS" : "OVR", 1), H - STATUS_H + 4, insert_mode ? "INS" : "OVR", C_GRAY, 1);
        if (status[0]) gui_text(W - 60 - gui_text_w(status, 1), H - STATUS_H + 4, status, C_CUR, 1);
    }
    gui_show();
}

static void open_file(void)
{
    char p[128];
    strcpy(p, path[0] ? path : "/");
    if (gui_file_dialog("Open a file", p, 0, 0)) load(p);
}

/* the cursor moved: with Shift, the selection follows */
static void moved(int old)
{
    if (keydown(KEY_LSHIFT) || keydown(KEY_RSHIFT)) { if (anchor < 0) anchor = old; }
    else anchor = -1;
    if (cur < 0) cur = 0;
    if (cur > size) cur = size;
    half = 0;
    follow();
}

static int key(int ch, int sc)
{
    int ctrl = gui_ctrl(ch, sc), old = cur, v;
    if (mode == 3) {
        if (ch == 'y' || ch == 'Y') return 1;
        mode = 0;
        return 0;
    }
    if (mode == 1 || mode == 2) {
        if (sc == KEY_ESC) { mode = 0; return 0; }
        if (ch == 13) {
            if (mode == 1) { if (parse_pattern()) { cur = cur > 0 ? cur - 1 : -1; find_next(); if (cur < 0) cur = 0; } }
            else {
                unsigned o = 0; int i;
                for (i = 0; field[i]; i++) if (hexval(field[i]) >= 0) o = o * 16 + hexval(field[i]);
                cur = o > (unsigned)size ? size : (int)o; anchor = -1; half = 0;
            }
            mode = 0;
            follow();
            return 0;
        }
        gui_field_key(field, sizeof field, ch);
        return 0;
    }
    status[0] = 0;
    if (ctrl) {
        int shift = keydown(KEY_LSHIFT) || keydown(KEY_RSHIFT);
        switch (sc) {
        case 0x18: open_file(); return 0;                          /* O */
        case 0x1F: save(shift); return 0;                          /* S */
        case 0x2C: undo(0); follow(); return 0;                    /* Z */
        case 0x15: undo(1); follow(); return 0;                    /* Y */
        case 0x21: mode = 1; field[0] = 0; return 0;               /* F */
        case 0x22: mode = 2; field[0] = 0; return 0;               /* G */
        case 0x47: cur = 0; moved(old); return 0;                  /* Home */
        case 0x4F: cur = size; moved(old); return 0;               /* End */
        }
        return 0;
    }
    if (sc == KEY_ESC) { if (dirty) { mode = 3; return 0; } return 1; }
    if (sc == 0x3D) { find_next(); follow(); return 0; }            /* F3 */
    if (!ch || ch == 0xE0) {
        switch (sc) {
        case KEY_LEFT:  cur--; moved(old); return 0;
        case KEY_RIGHT: cur++; moved(old); return 0;
        case KEY_UP:    if (cur >= 16) cur -= 16; moved(old); return 0;
        case KEY_DOWN:  if (cur + 16 <= size) cur += 16; else cur = size; moved(old); return 0;
        case 0x49: cur -= ROWS * 16; moved(old); return 0;                           /* PgUp */
        case 0x51: cur += ROWS * 16; moved(old); return 0;                           /* PgDn */
        case 0x47: cur -= cur % 16; moved(old); return 0;                            /* Home */
        case 0x4F: cur = cur - cur % 16 + 15; moved(old); return 0;                  /* End */
        case 0x52: insert_mode = !insert_mode; return 0;                             /* Insert */
        case 0x53:                                                                   /* Delete */
            group++;
            if (anchor >= 0) { int a = sel_a(); del_bytes(a, sel_b() - a + 1); cur = a; anchor = -1; }
            else if (cur < size) del_bytes(cur, 1);
            half = 0;
            return 0;
        }
    }
    if (ch == 9) { in_text = !in_text; half = 0; return 0; }
    if (ch == 8) {                                                  /* Backspace */
        group++;
        if (anchor >= 0) { int a = sel_a(); del_bytes(a, sel_b() - a + 1); cur = a; anchor = -1; }
        else if (cur > 0) { cur--; del_bytes(cur, 1); }
        half = 0; follow();
        return 0;
    }
    if (in_text) {
        if (ch < 32 || ch == 127) return 0;
        group++;
        if (insert_mode) ins_byte(cur, ch); else set_byte(cur, ch);
        cur++; anchor = -1; follow();
        return 0;
    }
    v = hexval(ch);
    if (v < 0) return 0;
    if (!half) group++;
    if (!half && (insert_mode || cur == size)) {                    /* a new byte, its high half */
        if (insert_mode) ins_byte(cur, v << 4); else set_byte(cur, v << 4);
        half = 1;
    } else if (!half) { set_byte(cur, (data[cur] & 0x0F) | v << 4); half = 1; }
    else { set_byte(cur, (data[cur] & 0xF0) | v); half = 0; cur++; }
    anchor = -1;
    follow();
    return 0;
}

static int button_at(int mx, int my)
{
    int i;
    if (my < 5 || my >= 29) return -1;
    for (i = 0; i < NBTN; i++) if (mx >= btn_x(i) && mx < btn_x(i) + btn_w(i)) return i;
    return -1;
}
static void press(int b)
{
    switch (b) {
    case 0: open_file(); break;
    case 1: save(0); break;
    case 2: save(1); break;
    case 3: undo(0); follow(); break;
    case 4: undo(1); follow(); break;
    case 5: mode = 1; field[0] = 0; break;
    case 6: mode = 2; field[0] = 0; break;
    case 7: insert_mode = !insert_mode; break;
    }
}

int main(int argc, char **argv)
{
    int m[4], was = 0, drag = 0;
    if (gui_open(W, H) < 0) { puts("hexedit: needs a 792x584 window in 32 bits\n"); return 1; }
    keymode(1);
    cap = 65536;
    data = malloc(cap);
    orig = malloc(1);
    if (argc > 1) {
        char p[128];
        int i;
        for (i = 0; argv[1][i] && i < 126; i++) p[i] = gui_upper(argv[1][i]);
        p[i] = 0;
        load(p);
    } else say("Ctrl+O opens a file.");
    draw();
    for (;;) {
        int k, changed = 0;
        char in[128];
        while ((k = pollkey())) {
            if (key(k & 0xFF, (k >> 8) & 0xFF)) return 0;
            changed = 1;
        }
        if (inbox(in, sizeof in) > 0) { load(in); changed = 1; }
        if (mouse(m)) {
            int mx = m[0], my = m[1], down = m[2] & 1, text = 0, p, h = button_at(mx, my);
            if (h != hover) { hover = h; changed = 1; }
            if (m[3]) { top += m[3] * 3; if (top > size / 16) top = size / 16; if (top < 0) top = 0; changed = 1; }
            if (down && !was) {
                if (h >= 0) press(h);
                else if (mx >= SB_X && my >= ROW_Y) drag = 2;
                else if ((p = byte_at(mx, my, &text)) >= 0) {
                    int old = cur;
                    cur = p; in_text = text; half = 0;
                    if (keydown(KEY_LSHIFT) || keydown(KEY_RSHIFT)) { if (anchor < 0) anchor = old; }
                    else anchor = p;
                    drag = 1;
                }
                changed = 1;
            } else if (down && drag == 1 && (p = byte_at(mx, my, &text)) >= 0 && p != cur) {
                cur = p; changed = 1;
            } else if (down && drag == 2) {
                int rows_all = size / 16 + 1;
                if (rows_all > ROWS) { top = (my - ROW_Y) * (rows_all - ROWS) / (ROWS * LINE_H); if (top < 0) top = 0; if (top > rows_all - ROWS) top = rows_all - ROWS; changed = 1; }
            }
            if (!down) { if (drag == 1 && anchor == cur) anchor = -1; drag = 0; }
            was = down;
        } else if (hover >= 0) { hover = -1; changed = 1; }
        if (changed) draw();
        sleep_ms(15);
    }
    return 0;
}
