/* sheet.c - LexOS Sheet: a spreadsheet, in a window.
 *
 *   run sheet.app [file.csv]      (Files opens .CSV files in it)
 *
 * A grid of cells, A1 to Z200. A cell holds a number, some text, or a
 * formula - "=" and then an expression:
 *
 *   =A1+B2*2     =(A1-A2)/A3     =2^10     =-A1
 *   =SUM(A1:A10)   AVERAGE MIN MAX COUNT   (ranges, or cells, or both)
 *   =ABS(x)  =SQRT(x)  =ROUND(x, 2)  =INT(x)  =MOD(a, b)
 *   =IF(A1>10, "big", "small")        (comparisons: < > = <= >= <>)
 *   =A1 & " kg"                       (text joined)
 *
 * Everything that depends on a cell changes with it. A reference with
 * $ ($A$1) stays put when copied; the others move with the copy.
 *
 * Typing starts writing into the cell (F2 or a double click: edit
 * what's there); Enter puts it in (and goes down), Tab (goes right),
 * Esc doesn't. Arrows move, Shift+arrows or the mouse select; Delete
 * empties what's selected. Ctrl+C / Ctrl+X / Ctrl+V copy, cut, paste;
 * Ctrl+Z / Ctrl+Y undo, redo. Ctrl+O open, Ctrl+S save, Ctrl+N new.
 * A column's edge in the header can be dragged wider. The status line
 * sums what's selected.
 *
 * Files are CSV: a line per row, cells between commas ("..." when they
 * have commas or quotes in them); formulas are kept as formulas. */
#include "gui.h"

#define W 800
#define H 572
#define NC 26
#define NR 200
#define TOOL_H 34
#define FBAR_Y TOOL_H
#define FBAR_H 30
#define GRID_Y (FBAR_Y + FBAR_H)
#define HEAD_H 20
#define ROW_H 20
#define RHEAD_W 40
#define STATUS_H 22
#define GRID_H (H - GRID_Y - STATUS_H)
#define VIS_ROWS ((GRID_H - HEAD_H) / ROW_H)
#define CELL_MAX 120
#define UNDO_MAX 2000

#define C_BG      RGB(255, 255, 255)
#define C_TEXT    RGB(28, 30, 36)
#define C_GRAY    RGB(120, 126, 138)
#define C_GRID    RGB(222, 226, 234)
#define C_HEAD    RGB(240, 242, 246)
#define C_HEAD_ON RGB(214, 226, 248)
#define C_BAR     RGB(226, 232, 242)
#define C_LINE    RGB(190, 198, 214)
#define C_ACCENT  RGB(40, 120, 70)
#define C_SELBG   RGB(226, 240, 230)
#define C_ERR     RGB(200, 50, 50)

struct cell {
    char *src;                  /* what was typed (NULL: empty) */
    double num;                 /* its value, if it's a number */
    char *str;                  /* its value, if it's text */
    char err;                   /* 1 an error (str says which) */
    char kind;                  /* 0 empty, 1 number, 2 text */
    char state;                 /* 0 not yet, 1 being worked out, 2 done */
};
static struct cell cells[NR][NC];
static int colw[NC];
static int cr, cc, ar = -1, ac = -1;            /* the cursor; the selection's other corner */
static int top, left;
static int editing, dirty, hover = -1;
static char ebuf[CELL_MAX];
static int ecur;
static char path[128], status[80];

/* ============================================================
 * cells' text
 * ============================================================ */
static char *dupstr(const char *s)
{
    char *p;
    if (!s || !*s) return 0;
    p = malloc(strlen(s) + 1);
    if (p) strcpy(p, s);
    return p;
}
static int is_digit(int c) { return c >= '0' && c <= '9'; }
static int is_alpha(int c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'); }

/* a number, to sig figures, in as few characters as fit: 12, 3.25, 1.5e+12 */
static void fmt_sig(double v, char *out, int sig)
{
    char dig[20];
    int e = 0, i, n = 0, neg = v < 0;
    double m;
    if (v != v || v - v != 0) { strcpy(out, "#NUM!"); return; }
    if (neg) v = -v;
    if (v < 5e-11) { strcpy(out, "0"); return; }
    m = v;
    while (m >= 10) { m /= 10; e++; }
    while (m < 1) { m *= 10; e--; }
    { double half = 5; for (i = 0; i < sig; i++) half /= 10; m += half; if (m >= 10) { m /= 10; e++; } }
    for (i = 0; i < sig; i++) { int d = (int)m; if (d > 9) d = 9; dig[i] = '0' + d; m = (m - d) * 10; }
    while (sig > 1 && dig[sig - 1] == '0') sig--;
    if (neg) out[n++] = '-';
    if (e >= 12 || e < -6) {
        out[n++] = dig[0];
        if (sig > 1) { out[n++] = '.'; for (i = 1; i < sig && i < 7; i++) out[n++] = dig[i]; }
        out[n++] = 'e'; out[n++] = e < 0 ? '-' : '+';
        if (e < 0) e = -e;
        if (e >= 100) out[n++] = '0' + e / 100;
        if (e >= 10) out[n++] = '0' + e / 10 % 10;
        out[n++] = '0' + e % 10;
    } else if (e < 0) {
        out[n++] = '0'; out[n++] = '.';
        for (i = -1; i > e; i--) out[n++] = '0';
        for (i = 0; i < sig; i++) out[n++] = dig[i];
    } else {
        for (i = 0; i <= e; i++) out[n++] = i < sig ? dig[i] : '0';
        if (sig > e + 1) { out[n++] = '.'; for (i = e + 1; i < sig; i++) out[n++] = dig[i]; }
    }
    out[n] = 0;
}
static void fmt_num(double v, char *out) { fmt_sig(v, out, 10); }
/* text -> a number, all of it (carry nothing after) -> 1 if it was one */
static int parse_num(const char *s, double *out)
{
    double v = 0, f = 0.1;
    int neg = 0, any = 0, e = 0, eneg = 0;
    while (*s == ' ') s++;
    if (*s == '-' || *s == '+') neg = *s++ == '-';
    while (is_digit(*s)) { v = v * 10 + (*s++ - '0'); any = 1; }
    if (*s == '.' || *s == ',') { s++; while (is_digit(*s)) { v += (*s++ - '0') * f; f /= 10; any = 1; } }
    if (any && (*s == 'e' || *s == 'E')) {
        s++;
        if (*s == '-' || *s == '+') eneg = *s++ == '-';
        while (is_digit(*s)) e = e * 10 + (*s++ - '0');
        while (e--) v = eneg ? v / 10 : v * 10;
    }
    while (*s == ' ') s++;
    if (!any || *s) return 0;
    *out = neg ? -v : v;
    return 1;
}
static void col_name(int c, char *o) { o[0] = 'A' + c; o[1] = 0; }
static void cell_name(int r, int c, char *o) { o[0] = 'A' + c; gui_num(o + 1, r + 1); }

/* ============================================================
 * formulas
 * ============================================================ */
struct val { double n; char s[CELL_MAX]; int text, err; };
static const char *fp;                           /* where the parser is */
static const char *ferr;                         /* the first error met */
static void eval_cell(int r, int c);

static void skip(void) { while (*fp == ' ') fp++; }
static void set_err(struct val *v, const char *e) { if (v->s != e) strcpy(v->s, e); v->err = 1; v->text = 1; if (!ferr) ferr = "#ERR!"; }
static void num_val(struct val *v, double n) { v->n = n; v->text = 0; v->err = 0; }

/* a cell reference at fp: A1, $A$1 -> 1, and its row/column */
static int ref_at(const char *p, int *r, int *c, int *len)
{
    const char *s = p;
    int col, row = 0;
    if (*s == '$') s++;
    if (!is_alpha(*s)) return 0;
    col = (*s >= 'a' ? *s - 'a' : *s - 'A');
    s++;
    if (is_alpha(*s)) return 0;                  /* (a word: a function) */
    if (*s == '$') s++;
    if (!is_digit(*s)) return 0;
    while (is_digit(*s)) row = row * 10 + (*s++ - '0');
    if (row < 1 || row > NR || col >= NC) return 0;
    *r = row - 1; *c = col; *len = s - p;
    return 1;
}
static void cell_val(int r, int c, struct val *v)
{
    struct cell *x = &cells[r][c];
    eval_cell(r, c);
    if (x->err) { set_err(v, x->str ? x->str : "#ERR!"); return; }
    if (x->kind == 2) { v->text = 1; v->err = 0; strcpy(v->s, x->str ? x->str : ""); v->n = 0; return; }
    num_val(v, x->kind == 1 ? x->num : 0);
}
static double as_num(struct val *v)
{
    double d;
    if (v->err) return 0;
    if (!v->text) return v->n;
    if (parse_num(v->s, &d)) return d;
    if (!v->s[0]) return 0;
    set_err(v, "#VALUE!");
    return 0;
}
static void as_text(struct val *v, char *o)
{
    if (v->text) strcpy(o, v->s);
    else fmt_num(v->n, o);
}

static void expr(struct val *v);

/* a function's arguments: each a value, or a range (numbers of it) */
#define ARGS_MAX 400
static double args[ARGS_MAX];
static int nargs, nonblank;
static struct val first_args[3];
static int nfirst;
static void fn_args(void)
{
    nargs = 0; nonblank = 0; nfirst = 0;
    skip();
    if (*fp == ')') { fp++; return; }
    for (;;) {
        int r1, c1, r2, c2, l1, l2;
        skip();
        if (ref_at(fp, &r1, &c1, &l1) && fp[l1] == ':' && ref_at(fp + l1 + 1, &r2, &c2, &l2)) {
            int r, c, t;
            fp += l1 + 1 + l2;
            if (r1 > r2) { t = r1; r1 = r2; r2 = t; }
            if (c1 > c2) { t = c1; c1 = c2; c2 = t; }
            for (r = r1; r <= r2; r++)
                for (c = c1; c <= c2; c++) {
                    struct val x;
                    cell_val(r, c, &x);
                    if (x.err) { set_err(&x, x.s); continue; }
                    if (!x.text && cells[r][c].kind == 1 && nargs < ARGS_MAX) { args[nargs++] = x.n; nonblank++; }
                    else if (x.text && x.s[0]) nonblank++;
                }
            if (nfirst < 3) { memset(&first_args[nfirst], 0, sizeof first_args[0]); nfirst++; }
        } else {
            struct val x;
            expr(&x);
            if (nfirst < 3) first_args[nfirst++] = x;
            if (!x.err && !x.text && nargs < ARGS_MAX) { args[nargs++] = x.n; nonblank++; }
            else if (!x.err && x.text) { double d; if (parse_num(x.s, &d) && nargs < ARGS_MAX) args[nargs++] = d; nonblank++; }
        }
        skip();
        if (*fp == ',' || *fp == ';') { fp++; continue; }
        if (*fp == ')') { fp++; return; }
        if (!ferr) ferr = "#ERR!";
        return;
    }
}
static int word_is(const char *w, const char *name)
{
    while (*name) if (gui_upper(*w++) != *name++) return 0;
    return !is_alpha(*w);
}
static double rnd(double x) { return x < 0 ? -floor(-x + 0.5) : floor(x + 0.5); }

static void primary(struct val *v)
{
    int r, c, l;
    skip();
    num_val(v, 0);
    if (*fp == '(') { fp++; expr(v); skip(); if (*fp == ')') fp++; else set_err(v, "#ERR!"); return; }
    if (*fp == '-') { fp++; primary(v); num_val(v, -as_num(v)); return; }
    if (*fp == '+') { fp++; primary(v); return; }
    if (*fp == '"') {                              /* "text" */
        int n = 0;
        fp++;
        while (*fp && *fp != '"' && n < CELL_MAX - 1) v->s[n++] = *fp++;
        v->s[n] = 0;
        if (*fp == '"') fp++;
        v->text = 1;
        return;
    }
    if (is_digit(*fp) || *fp == '.') {
        double d = 0, f = 0.1;
        while (is_digit(*fp)) d = d * 10 + (*fp++ - '0');
        if (*fp == '.') { fp++; while (is_digit(*fp)) { d += (*fp++ - '0') * f; f /= 10; } }
        num_val(v, d);
        return;
    }
    if (ref_at(fp, &r, &c, &l)) { fp += l; cell_val(r, c, v); return; }
    if (is_alpha(*fp)) {                           /* a function */
        const char *w = fp;
        while (is_alpha(*fp) || is_digit(*fp)) fp++;
        skip();
        if (*fp != '(') { set_err(v, "#NAME?"); return; }
        fp++;
        fn_args();
        if (word_is(w, "SUM")) { double s = 0; int i; for (i = 0; i < nargs; i++) s += args[i]; num_val(v, s); }
        else if (word_is(w, "AVERAGE") || word_is(w, "AVG")) {
            double s = 0; int i;
            for (i = 0; i < nargs; i++) s += args[i];
            if (!nargs) set_err(v, "#DIV/0!"); else num_val(v, s / nargs);
        }
        else if (word_is(w, "MIN") || word_is(w, "MAX")) {
            int i, mx = word_is(w, "MAX");
            double m = nargs ? args[0] : 0;
            for (i = 1; i < nargs; i++) if (mx ? args[i] > m : args[i] < m) m = args[i];
            num_val(v, m);
        }
        else if (word_is(w, "COUNT")) num_val(v, nargs);
        else if (word_is(w, "COUNTA")) num_val(v, nonblank);
        else if (word_is(w, "ABS")) num_val(v, nargs ? fabs(args[0]) : 0);
        else if (word_is(w, "SQRT")) { if (nargs && args[0] >= 0) num_val(v, sqrt(args[0])); else set_err(v, "#NUM!"); }
        else if (word_is(w, "INT")) num_val(v, nargs ? floor(args[0]) : 0);
        else if (word_is(w, "ROUND")) {
            double x = nargs ? args[0] : 0, k = 1; int d = nargs > 1 ? (int)args[1] : 0, i;
            for (i = 0; i < d && i < 10; i++) k *= 10;
            num_val(v, rnd(x * k) / k);
        }
        else if (word_is(w, "MOD")) {
            if (nargs < 2 || args[1] == 0) set_err(v, "#DIV/0!");
            else { double q = floor(args[0] / args[1]); num_val(v, args[0] - q * args[1]); }
        }
        else if (word_is(w, "POWER")) num_val(v, nargs > 1 ? pow(args[0], args[1]) : 0);
        else if (word_is(w, "PI")) num_val(v, M_PI);
        else if (word_is(w, "IF")) {
            if (nfirst < 2) { set_err(v, "#ERR!"); return; }
            {
                struct val *t = &first_args[0];
                int yes = t->text ? t->s[0] != 0 : t->n != 0;
                if (yes) *v = first_args[1];
                else if (nfirst > 2) *v = first_args[2];
                else num_val(v, 0);
            }
        }
        else set_err(v, "#NAME?");
        return;
    }
    set_err(v, "#ERR!");
}
static void power(struct val *v)
{
    primary(v);
    skip();
    while (*fp == '^') {
        struct val b;
        fp++;
        primary(&b);
        num_val(v, pow(as_num(v), as_num(&b)));
        skip();
    }
}
static void term(struct val *v)
{
    power(v);
    for (;;) {
        struct val b;
        char op;
        skip();
        if (*fp != '*' && *fp != '/') return;
        op = *fp++;
        power(&b);
        {
            double x = as_num(v), y = as_num(&b);
            if (v->err || b.err) { if (!v->err) *v = b; return; }
            if (op == '/' && y == 0) { set_err(v, "#DIV/0!"); return; }
            num_val(v, op == '*' ? x * y : x / y);
        }
    }
}
static void sum(struct val *v)
{
    term(v);
    for (;;) {
        struct val b;
        char op;
        skip();
        if (*fp != '+' && *fp != '-') return;
        op = *fp++;
        term(&b);
        if (v->err || b.err) { if (!v->err) *v = b; continue; }
        num_val(v, op == '+' ? as_num(v) + as_num(&b) : as_num(v) - as_num(&b));
    }
}
static void concat(struct val *v)
{
    sum(v);
    for (;;) {
        struct val b;
        char x[CELL_MAX], y[CELL_MAX];
        skip();
        if (*fp != '&') return;
        fp++;
        sum(&b);
        if (v->err || b.err) { if (!v->err) *v = b; continue; }
        as_text(v, x); as_text(&b, y);
        if (strlen(x) + strlen(y) >= CELL_MAX) y[CELL_MAX - 1 - strlen(x)] = 0;
        gui_cat(x, y);
        strcpy(v->s, x); v->text = 1;
    }
}
static void expr(struct val *v)
{
    concat(v);
    skip();
    if (*fp == '<' || *fp == '>' || *fp == '=') {
        struct val b;
        int op = *fp++, r;
        if (op == '<' && *fp == '>') { op = '!'; fp++; }
        else if (*fp == '=') { op = op == '<' ? 'l' : op == '>' ? 'g' : '='; fp++; }
        concat(&b);
        if (v->err || b.err) { if (!v->err) *v = b; return; }
        if (v->text || b.text) {
            char x[CELL_MAX], y[CELL_MAX];
            as_text(v, x); as_text(&b, y);
            r = strcmp(x, y);
        } else r = v->n < b.n ? -1 : v->n > b.n ? 1 : 0;
        switch (op) {
        case '<': r = r < 0; break;   case '>': r = r > 0; break;
        case 'l': r = r <= 0; break;  case 'g': r = r >= 0; break;
        case '=': r = r == 0; break;  default:  r = r != 0; break;
        }
        num_val(v, r);
    }
}

static void clear_value(struct cell *x) { free(x->str); x->str = 0; x->kind = 0; x->err = 0; x->num = 0; }
static void eval_cell(int r, int c)
{
    struct cell *x = &cells[r][c];
    const char *save_fp = fp, *save_err = ferr;
    if (x->state == 2) return;
    if (x->state == 1) { clear_value(x); x->err = 1; x->kind = 2; x->str = dupstr("#CYCLE!"); x->state = 2; return; }
    clear_value(x);
    if (!x->src) { x->state = 2; return; }
    if (x->src[0] == '=') {
        struct val v;
        x->state = 1;
        fp = x->src + 1; ferr = 0;
        expr(&v);
        skip();
        if (*fp && !v.err) set_err(&v, "#ERR!");
        if (x->state == 2) { fp = save_fp; ferr = save_err; return; }   /* (a cycle, marked) */
        if (v.err) { x->err = 1; x->kind = 2; x->str = dupstr(v.s); }
        else if (v.text) { x->kind = 2; x->str = dupstr(v.s); }
        else { x->kind = 1; x->num = v.n; }
        fp = save_fp; ferr = save_err;
    } else if (parse_num(x->src, &x->num)) x->kind = 1;
    else { x->kind = 2; x->str = dupstr(x->src); }
    x->state = 2;
}
static void recalc(void)
{
    int r, c;
    for (r = 0; r < NR; r++) for (c = 0; c < NC; c++) cells[r][c].state = 0;
    for (r = 0; r < NR; r++) for (c = 0; c < NC; c++) eval_cell(r, c);
}

/* ============================================================
 * changes (and undo)
 * ============================================================ */
struct change { short r, c; char *was, *is; int group; };
static struct change ulog[UNDO_MAX];
static int nu, nu_top, ugroup;

static void set_src(int r, int c, const char *s, int log)
{
    struct cell *x = &cells[r][c];
    if (!s || !*s) s = 0;
    if ((!s && !x->src) || (s && x->src && !strcmp(s, x->src))) return;
    if (log) {
        int i;
        for (i = nu; i < nu_top; i++) { free(ulog[i].was); free(ulog[i].is); }
        if (nu >= UNDO_MAX) { free(ulog[0].was); free(ulog[0].is); memmove(ulog, ulog + 1, (UNDO_MAX - 1) * sizeof ulog[0]); nu--; }
        ulog[nu].r = r; ulog[nu].c = c; ulog[nu].was = dupstr(x->src); ulog[nu].is = dupstr(s); ulog[nu].group = ugroup;
        nu++; nu_top = nu;
    }
    free(x->src);
    x->src = dupstr(s);
    dirty = 1;
}
static void undo(int redo)
{
    int g;
    if (!redo) {
        if (!nu) { strcpy(status, "Nothing to undo."); return; }
        g = ulog[nu - 1].group;
        while (nu && ulog[nu - 1].group == g) { nu--; set_src(ulog[nu].r, ulog[nu].c, ulog[nu].was, 0); cr = ulog[nu].r; cc = ulog[nu].c; }
    } else {
        if (nu >= nu_top) { strcpy(status, "Nothing to redo."); return; }
        g = ulog[nu].group;
        while (nu < nu_top && ulog[nu].group == g) { set_src(ulog[nu].r, ulog[nu].c, ulog[nu].is, 0); cr = ulog[nu].r; cc = ulog[nu].c; nu++; }
    }
    ar = -1;
    recalc();
}

/* a formula moved by dr rows, dc columns: its references (not $ ones) with it */
static void shift_refs(const char *s, int dr, int dc, char *o, int n)
{
    int k = 0, in_q = 0;
    const char *p = s;
    if (*p != '=') { strcpy(o, s); return; }
    while (*p && k < n - 8) {
        int r, c, l;
        if (*p == '"') in_q = !in_q;
        if (!in_q && (p == s || !is_alpha(p[-1])) && ref_at(p, &r, &c, &l)) {
            int abs_c = p[0] == '$', abs_r = 0, i;
            for (i = 1; i < l; i++) if (p[i] == '$') abs_r = 1;
            if (!abs_c) c += dc;
            if (!abs_r) r += dr;
            if (c < 0 || c >= NC || r < 0 || r >= NR) { strcpy(o + k, "#REF!"); k += 5; p += l; continue; }
            if (abs_c) o[k++] = '$';
            o[k++] = 'A' + c;
            if (abs_r) o[k++] = '$';
            gui_num(o + k, r + 1);
            k += strlen(o + k);
            p += l;
            continue;
        }
        o[k++] = *p++;
    }
    o[k] = 0;
}

/* ============================================================
 * the clipboard (this program's own)
 * ============================================================ */
static char **clip;
static int clip_r, clip_c, clip_h, clip_w, clip_cut;

static void sel_rect(int *r1, int *c1, int *r2, int *c2)
{
    if (ar < 0) { *r1 = *r2 = cr; *c1 = *c2 = cc; return; }
    *r1 = ar < cr ? ar : cr; *r2 = ar < cr ? cr : ar;
    *c1 = ac < cc ? ac : cc; *c2 = ac < cc ? cc : ac;
}
static void copy_sel(int cut)
{
    int r1, c1, r2, c2, r, c;
    sel_rect(&r1, &c1, &r2, &c2);
    if (clip) { for (r = 0; r < clip_h * clip_w; r++) free(clip[r]); free(clip); }
    clip_h = r2 - r1 + 1; clip_w = c2 - c1 + 1;
    clip = malloc(clip_h * clip_w * sizeof *clip);
    if (!clip) return;
    for (r = r1; r <= r2; r++) for (c = c1; c <= c2; c++) clip[(r - r1) * clip_w + c - c1] = dupstr(cells[r][c].src);
    clip_r = r1; clip_c = c1; clip_cut = cut;
    strcpy(status, cut ? "Cut: Ctrl+V puts it somewhere." : "Copied.");
}
static void paste(void)
{
    int r, c;
    char buf[CELL_MAX * 2];
    if (!clip) return;
    ugroup++;
    if (clip_cut)
        for (r = 0; r < clip_h; r++) for (c = 0; c < clip_w; c++) set_src(clip_r + r, clip_c + c, 0, 1);
    for (r = 0; r < clip_h; r++)
        for (c = 0; c < clip_w; c++) {
            const char *s = clip[r * clip_w + c];
            if (cr + r >= NR || cc + c >= NC) continue;
            if (s && s[0] == '=' && !clip_cut) { shift_refs(s, cr - clip_r, cc - clip_c, buf, sizeof buf); s = buf; }
            if (s && strlen(s) >= CELL_MAX) continue;
            set_src(cr + r, cc + c, s, 1);
        }
    clip_cut = 0;
    ar = cr + clip_h - 1 < NR ? cr + clip_h - 1 : NR - 1;
    ac = cc + clip_w - 1 < NC ? cc + clip_w - 1 : NC - 1;
    if (ar == cr && ac == cc) ar = -1;
    recalc();
}

/* ============================================================
 * files (CSV)
 * ============================================================ */
static void clear_all(void)
{
    int r, c;
    for (r = 0; r < NR; r++) for (c = 0; c < NC; c++) { free(cells[r][c].src); cells[r][c].src = 0; clear_value(&cells[r][c]); }
    for (r = 0; r < nu_top; r++) { free(ulog[r].was); free(ulog[r].is); }
    nu = nu_top = 0;
    cr = cc = top = left = 0; ar = -1; dirty = 0;
}
static void load(const char *p)
{
    int fd = open(p, O_READ), n, i = 0, r = 0, c = 0, k = 0, q = 0;
    char *b, field[CELL_MAX];
    if (fd < 0) { strcpy(status, "Can't open it."); return; }
    n = fsize(fd);
    b = malloc(n + 1);
    if (!b) { close(fd); strcpy(status, "Out of memory."); return; }
    n = read(fd, b, n);
    close(fd);
    if (n < 0) n = 0;
    clear_all();
    for (i = 0; i <= n; i++) {
        char ch = i < n ? b[i] : '\n';
        if (q) {
            if (ch == '"') { if (i + 1 < n && b[i + 1] == '"') { if (k < CELL_MAX - 1) field[k++] = '"'; i++; } else q = 0; }
            else if (k < CELL_MAX - 1) field[k++] = ch;
            continue;
        }
        if (ch == '"' && k == 0) { q = 1; continue; }
        if (ch == '\r') continue;
        if (ch == ',' || ch == ';' || ch == '\n') {
            field[k] = 0;
            if (r < NR && c < NC && k) { free(cells[r][c].src); cells[r][c].src = dupstr(field); }
            k = 0;
            if (ch == '\n') { r++; c = 0; } else c++;
            continue;
        }
        if (k < CELL_MAX - 1) field[k++] = ch;
    }
    free(b);
    strcpy(path, p);
    dirty = 0;
    recalc();
    status[0] = 0;
}
static void save(int as)
{
    int fd, r, c, lr = -1, lc, i;
    if (as || !path[0]) {
        char p[128];
        strcpy(p, path[0] ? path : "/");
        if (!gui_file_dialog("Save as", p, 1, 0)) return;
        {                                          /* no extension: .CSV */
            int dot = 0;
            for (i = 0; p[i]; i++) { if (p[i] == '.') dot = 1; if (p[i] == '/') dot = 0; }
            if (!dot) gui_cat(p, ".CSV");
        }
        strcpy(path, p);
    }
    fd = open(path, O_WRITE);
    if (fd < 0) { strcpy(status, "Can't save it there."); return; }
    for (r = 0; r < NR; r++) for (c = 0; c < NC; c++) if (cells[r][c].src) lr = r;
    for (r = 0; r <= lr; r++) {
        lc = -1;
        for (c = 0; c < NC; c++) if (cells[r][c].src) lc = c;
        for (c = 0; c <= lc; c++) {
            const char *s = cells[r][c].src;
            if (c) fwrite(fd, ",", 1);
            if (!s) continue;
            {
                int need = 0;
                for (i = 0; s[i]; i++) if (s[i] == ',' || s[i] == '"' || s[i] == ';') need = 1;
                if (!need) { fwrite(fd, s, strlen(s)); continue; }
                fwrite(fd, "\"", 1);
                for (i = 0; s[i]; i++) { if (s[i] == '"') fwrite(fd, "\"", 1); fwrite(fd, s + i, 1); }
                fwrite(fd, "\"", 1);
            }
        }
        fwrite(fd, "\r\n", 2);
    }
    close(fd);
    dirty = 0;
    strcpy(status, "Saved.");
}

/* ============================================================
 * drawing
 * ============================================================ */
static int col_x(int c) { int x = RHEAD_W, i; for (i = left; i < c; i++) x += colw[i]; return x; }
static int vis_cols(void) { int x = RHEAD_W, c = left, n = 0; while (c < NC && x < W) { x += colw[c++]; n++; } return n; }
static void follow(void)
{
    if (cr < top) top = cr;
    if (cr >= top + VIS_ROWS) top = cr - VIS_ROWS + 1;
    if (cc < left) left = cc;
    while (col_x(cc) + colw[cc] > W && left < cc) left++;
}
static const char *btn_label[] = { "New", "Open", "Save", "Save as", "Undo", "Redo", "Sum" };
#define NBTN 7
static int btn_x(int i) { int x = 8, k; for (k = 0; k < i; k++) x += gui_text_w(btn_label[k], 1) + 22; return x; }
static int btn_w(int i) { return gui_text_w(btn_label[i], 1) + 16; }

static void cell_text(int r, int c, char *o)
{
    struct cell *x = &cells[r][c];
    if (x->kind == 1) fmt_num(x->num, o);
    else if (x->kind == 2) { int n = strlen(x->str ? x->str : ""); if (n >= CELL_MAX) n = CELL_MAX - 1; memcpy(o, x->str ? x->str : "", n); o[n] = 0; }
    else o[0] = 0;
}
static void draw(void)
{
    int r, c, i, r1, c1, r2, c2, nv = vis_cols();
    char t[CELL_MAX + 8], n[16];
    sel_rect(&r1, &c1, &r2, &c2);
    gui_fill(0, 0, W, H, C_BG);
    /* the buttons, the file */
    gui_fill(0, 0, W, TOOL_H, C_BAR);
    for (i = 0; i < NBTN; i++) gui_button(btn_x(i), 5, btn_w(i), 24, btn_label[i], hover == i);
    strcpy(t, path[0] ? path : "(new)");
    if (dirty) gui_cat(t, " *");
    gui_text_n(btn_x(NBTN) + 8, 9, t, (W - btn_x(NBTN) - 16) / 8, C_GRAY);
    /* the formula bar: the cell's name, what's in it */
    gui_fill(0, FBAR_Y, W, FBAR_H, RGB(248, 249, 251));
    gui_fill(0, FBAR_Y + FBAR_H - 1, W, 1, C_LINE);
    cell_name(cr, cc, n);
    gui_round(8, FBAR_Y + 4, 56, 22, 3, C_HEAD);
    gui_text_c(36, FBAR_Y + 7, n, C_TEXT, 1);
    gui_text(72, FBAR_Y + 7, "=", C_GRAY, 1);
    if (editing) {
        gui_field(88, FBAR_Y + 3, W - 96, ebuf, 1);
        gui_fill(88, FBAR_Y + 3, W - 96, 24, RGB(255, 255, 255));
        gui_box(88, FBAR_Y + 3, W - 96, 24, C_ACCENT);
        gui_text_n(94, FBAR_Y + 7, ebuf, (W - 108) / 8, C_TEXT);
        gui_fill(94 + ecur * 8, FBAR_Y + 7, 2, 16, C_ACCENT);
    } else gui_text_n(94, FBAR_Y + 7, cells[cr][cc].src ? cells[cr][cc].src : "", (W - 108) / 8, C_TEXT);
    /* the heads */
    gui_fill(0, GRID_Y, W, HEAD_H, C_HEAD);
    gui_fill(0, GRID_Y, RHEAD_W, GRID_H, C_HEAD);
    for (c = left; c < left + nv; c++) {
        int x = col_x(c);
        if (c >= c1 && c <= c2) gui_fill(x, GRID_Y, colw[c], HEAD_H, C_HEAD_ON);
        col_name(c, n);
        gui_text_c(x + colw[c] / 2, GRID_Y + 2, n, C_TEXT, 1);
        gui_fill(x + colw[c] - 1, GRID_Y, 1, GRID_H, C_GRID);
    }
    for (r = top; r < top + VIS_ROWS && r < NR; r++) {
        int y = GRID_Y + HEAD_H + (r - top) * ROW_H;
        if (r >= r1 && r <= r2) gui_fill(0, y, RHEAD_W, ROW_H, C_HEAD_ON);
        gui_num(n, r + 1);
        gui_text(RHEAD_W - 6 - gui_text_w(n, 1), y + 2, n, C_GRAY, 1);
        gui_fill(0, y + ROW_H - 1, W, 1, C_GRID);
    }
    gui_fill(RHEAD_W - 1, GRID_Y, 1, GRID_H, C_LINE);
    gui_fill(0, GRID_Y + HEAD_H - 1, W, 1, C_LINE);
    /* the cells: the selection's shade, then what's in them */
    for (r = top; r < top + VIS_ROWS && r < NR; r++) {
        int y = GRID_Y + HEAD_H + (r - top) * ROW_H;
        for (c = left; c < left + nv; c++) {
            int x = col_x(c), tw, maxc, over = 0;
            struct cell *cl = &cells[r][c];
            if (r >= r1 && r <= r2 && c >= c1 && c <= c2 && (r != cr || c != cc)) gui_fill(x, y, colw[c] - 1, ROW_H - 1, C_SELBG);
            if (!cl->kind) continue;
            cell_text(r, c, t);
            maxc = (colw[c] - 8) / 8;
            if (cl->kind == 2 && !cl->err) {           /* text runs on over empty neighbours */
                int k = c + 1;
                while (k < left + nv && !cells[r][k].kind && (int)strlen(t) > maxc + over / 8) over += colw[k++];
                maxc += over / 8;
            }
            if (cl->kind == 1) {                       /* a number: fewer figures, as fit */
                int sig = 9;
                while ((int)strlen(t) > maxc && sig > 0) fmt_sig(cl->num, t, sig--);
            }
            if ((int)strlen(t) > maxc && cl->kind == 1) { t[0] = 0; for (tw = 0; tw < maxc && tw < 20; tw++) t[tw] = '#'; t[tw] = 0; }
            tw = gui_text_w(t, 1);
            if (cl->kind == 1) gui_text(x + colw[c] - 5 - tw, y + 2, t, C_TEXT, 1);
            else gui_text_n(x + 4, y + 2, t, maxc, cl->err ? C_ERR : C_TEXT);
        }
    }
    /* the cursor */
    if (cr >= top && cr < top + VIS_ROWS && cc >= left && cc < left + nv) {
        int x = col_x(cc), y = GRID_Y + HEAD_H + (cr - top) * ROW_H;
        gui_box(x - 1, y - 1, colw[cc] + 1, ROW_H + 1, C_ACCENT);
        gui_box(x, y, colw[cc] - 1, ROW_H - 1, C_ACCENT);
        gui_fill(x + colw[cc] - 4, y + ROW_H - 4, 5, 5, C_ACCENT);
    }
    /* the status line: sum / average / count of the selection */
    gui_fill(0, H - STATUS_H, W, STATUS_H, RGB(236, 238, 242));
    gui_fill(0, H - STATUS_H, W, 1, C_LINE);
    {
        double s = 0; int cnt = 0;
        for (r = r1; r <= r2; r++) for (c = c1; c <= c2; c++) if (cells[r][c].kind == 1) { s += cells[r][c].num; cnt++; }
        t[0] = 0;
        if (cnt > 1 || ar >= 0) {
            char v[32];
            strcpy(t, "Sum "); fmt_num(s, v); gui_cat(t, v);
            if (cnt) { gui_cat(t, "   Average "); fmt_num(s / cnt, v); gui_cat(t, v); }
            gui_cat(t, "   Count "); gui_cat(t, gui_num(v, cnt));
        } else if (cells[cr][cc].err) strcpy(t, "An error: see what the formula uses.");
        gui_text(8, H - STATUS_H + 3, t, C_TEXT, 1);
        if (status[0]) gui_text(W - 8 - gui_text_w(status, 1), H - STATUS_H + 3, status, C_ACCENT, 1);
    }
    gui_show();
}

/* ============================================================
 * keys and the mouse
 * ============================================================ */
static void start_edit(int keep, int ch)
{
    editing = 1;
    ebuf[0] = 0;
    if (keep && cells[cr][cc].src) strcpy(ebuf, cells[cr][cc].src);
    if (ch) { ebuf[0] = ch; ebuf[1] = 0; }
    ecur = strlen(ebuf);
}
static void commit(void)
{
    ugroup++;
    set_src(cr, cc, ebuf, 1);
    editing = 0;
    recalc();
}
static void moved(int shift, int old_r, int old_c)
{
    if (cr < 0) cr = 0;
    if (cr >= NR) cr = NR - 1;
    if (cc < 0) cc = 0;
    if (cc >= NC) cc = NC - 1;
    if (shift) { if (ar < 0) { ar = old_r; ac = old_c; } }
    else ar = -1;
    if (ar == cr && ac == cc) ar = -1;
    follow();
}
static void open_file(void)
{
    char p[128];
    strcpy(p, path[0] ? path : "/");
    if (gui_file_dialog("Open a sheet", p, 0, "CSV TXT")) load(p);
}
static void auto_sum(void)
{
    /* the numbers above the cursor (or to its left): =SUM() of them */
    int r = cr - 1, c = cc - 1;
    char f[40], a[8], b[8];
    if (r >= 0 && cells[r][cc].kind == 1) {
        while (r > 0 && cells[r - 1][cc].kind == 1) r--;
        cell_name(r, cc, a); cell_name(cr - 1, cc, b);
    } else if (c >= 0 && cells[cr][c].kind == 1) {
        while (c > 0 && cells[cr][c - 1].kind == 1) c--;
        cell_name(cr, c, a); cell_name(cr, cc - 1, b);
    } else { strcpy(status, "Sum: put the cursor under numbers."); return; }
    strcpy(f, "=SUM("); gui_cat(f, a); gui_cat(f, ":"); gui_cat(f, b); gui_cat(f, ")");
    ugroup++;
    set_src(cr, cc, f, 1);
    recalc();
}
static int quit_asked;
static int key(int ch, int sc)
{
    int shift = keydown(KEY_LSHIFT) || keydown(KEY_RSHIFT), ctrl = gui_ctrl(ch, sc);
    int or_ = cr, oc = cc;
    if (quit_asked) { quit_asked = 0; return ch == 'y' || ch == 'Y'; }
    status[0] = 0;
    if (editing) {
        int l = strlen(ebuf);
        if (sc == KEY_ESC) { editing = 0; return 0; }
        if (ch == 13) { commit(); cr++; moved(0, or_, oc); return 0; }
        if (ch == 9) { commit(); cc++; moved(0, or_, oc); return 0; }
        if (ch == 8) { if (ecur) { memmove(ebuf + ecur - 1, ebuf + ecur, l - ecur + 1); ecur--; } return 0; }
        if (!ch || ch == 0xE0) {
            if (sc == KEY_LEFT && ecur) ecur--;
            else if (sc == KEY_RIGHT && ecur < l) ecur++;
            else if (sc == 0x47) ecur = 0;
            else if (sc == 0x4F) ecur = l;
            else if (sc == 0x53 && ecur < l) memmove(ebuf + ecur, ebuf + ecur + 1, l - ecur);
            else if (sc == KEY_UP || sc == KEY_DOWN) {         /* (as Enter, then that way) */
                commit(); cr += sc == KEY_UP ? -1 : 1; moved(0, or_, oc);
            }
            return 0;
        }
        if (ch >= 32 && l < CELL_MAX - 1) { memmove(ebuf + ecur + 1, ebuf + ecur, l - ecur + 1); ebuf[ecur++] = ch; }
        return 0;
    }
    if (ctrl) {
        switch (sc) {
        case 0x2E: copy_sel(0); return 0;                        /* C */
        case 0x2D: copy_sel(1); return 0;                        /* X */
        case 0x2F: paste(); return 0;                            /* V */
        case 0x2C: undo(0); follow(); return 0;                  /* Z */
        case 0x15: undo(1); follow(); return 0;                  /* Y */
        case 0x18: open_file(); return 0;                        /* O */
        case 0x1F: save(shift); return 0;                        /* S */
        case 0x31: clear_all(); path[0] = 0; return 0;           /* N */
        case 0x1E: ar = NR - 1; ac = NC - 1; cr = 0; cc = 0; follow(); return 0;  /* A */
        case 0x47: cr = 0; cc = 0; moved(shift, or_, oc); return 0;               /* Home */
        }
        return 0;
    }
    if (sc == KEY_ESC) {
        if (ar >= 0) { ar = -1; return 0; }
        if (dirty) { quit_asked = 1; strcpy(status, "Changes aren't saved. Quit? Y / N"); return 0; }
        return 1;
    }
    if (!ch || ch == 0xE0) {
        switch (sc) {
        case KEY_UP: cr--; break;
        case KEY_DOWN: cr++; break;
        case KEY_LEFT: cc--; break;
        case KEY_RIGHT: cc++; break;
        case 0x49: cr -= VIS_ROWS; break;
        case 0x51: cr += VIS_ROWS; break;
        case 0x47: cc = 0; break;
        case 0x3C: start_edit(1, 0); return 0;                  /* F2 */
        case 0x53: {                                             /* Delete */
            int r1, c1, r2, c2, r, c;
            sel_rect(&r1, &c1, &r2, &c2);
            ugroup++;
            for (r = r1; r <= r2; r++) for (c = c1; c <= c2; c++) set_src(r, c, 0, 1);
            recalc();
            return 0;
        }
        default: return 0;
        }
        moved(shift, or_, oc);
        return 0;
    }
    if (ch == 13) { cr++; moved(0, or_, oc); return 0; }
    if (ch == 9) { cc += shift ? -1 : 1; moved(0, or_, oc); return 0; }
    if (ch == 8) { start_edit(0, 0); return 0; }
    if (ch >= 32) { ar = -1; start_edit(0, ch); }
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
    case 0: clear_all(); path[0] = 0; break;
    case 1: open_file(); break;
    case 2: save(0); break;
    case 3: save(1); break;
    case 4: undo(0); follow(); break;
    case 5: undo(1); follow(); break;
    case 6: auto_sum(); break;
    }
}
/* the cell at a point -> 1 (and r, c) */
static int cell_at(int mx, int my, int *r, int *c)
{
    int k, x = RHEAD_W;
    if (my < GRID_Y + HEAD_H || my >= H - STATUS_H || mx < RHEAD_W) return 0;
    *r = top + (my - GRID_Y - HEAD_H) / ROW_H;
    if (*r >= NR) return 0;
    for (k = left; k < NC; k++) { if (mx < x + colw[k]) { *c = k; return 1; } x += colw[k]; }
    return 0;
}
/* a column's right edge in the header, near mx -> the column, or -1 */
static int edge_at(int mx, int my)
{
    int k, x = RHEAD_W;
    if (my < GRID_Y || my >= GRID_Y + HEAD_H) return -1;
    for (k = left; k < NC; k++) { x += colw[k]; if (mx >= x - 4 && mx <= x + 3) return k; if (x > W) break; }
    return -1;
}

int main(int argc, char **argv)
{
    int m[4], was = 0, drag = 0, resize = -1, i;
    unsigned last_click = 0;
    if (gui_open(W, H) < 0) { puts("sheet: needs an 800x572 window in 32 bits\n"); return 1; }
    keymode(1);
    for (i = 0; i < NC; i++) colw[i] = 84;
    if (argc > 1) {
        char p[128];
        for (i = 0; argv[1][i] && i < 126; i++) p[i] = gui_upper(argv[1][i]);
        p[i] = 0;
        load(p);
        if (!path[0]) strcpy(path, p);                 /* (a new one: that name) */
    } else strcpy(status, "Type into a cell; = starts a formula.");
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
            int mx = m[0], my = m[1], down = m[2] & 1, r, c, h = button_at(mx, my);
            if (h != hover) { hover = h; changed = 1; }
            if (m[3]) { top += m[3] * 3; if (top > NR - VIS_ROWS) top = NR - VIS_ROWS; if (top < 0) top = 0; changed = 1; }
            if (down && !was) {
                unsigned now = millis();
                int dbl = now - last_click < 400;
                last_click = now;
                changed = 1;
                if (h >= 0) { if (editing) commit(); press(h); }
                else if ((resize = edge_at(mx, my)) >= 0) { }
                else if (cell_at(mx, my, &r, &c)) {
                    if (editing) {                          /* a formula: the cell's name goes in */
                        if (ebuf[0] == '=' && (r != cr || c != cc)) {
                            char nm[8]; int l = strlen(ebuf), nl;
                            cell_name(r, c, nm); nl = strlen(nm);
                            if (l + nl < CELL_MAX - 1) { memmove(ebuf + ecur + nl, ebuf + ecur, l - ecur + 1); memcpy(ebuf + ecur, nm, nl); ecur += nl; }
                            was = down;
                            continue;
                        }
                        commit();
                    }
                    if (dbl && r == cr && c == cc) start_edit(1, 0);
                    else {
                        int or_ = cr, oc = cc;
                        cr = r; cc = c;
                        if (keydown(KEY_LSHIFT) || keydown(KEY_RSHIFT)) { if (ar < 0) { ar = or_; ac = oc; } }
                        else ar = -1;
                        drag = 1;
                    }
                } else if (my >= GRID_Y && my < GRID_Y + HEAD_H && cell_at(mx, GRID_Y + HEAD_H, &r, &c)) {
                    if (editing) commit();                    /* a column's head: all of it */
                    cc = c; cr = top; ar = NR - 1; ac = c; cr = 0;
                }
            } else if (down && resize >= 0) {
                int w = mx - col_x(resize);
                if (w < 24) w = 24;
                if (w > 400) w = 400;
                if (w != colw[resize]) { colw[resize] = w; changed = 1; }
            } else if (down && drag && cell_at(mx, my, &r, &c)) {
                int anchor_r = ar < 0 ? cr : ar, anchor_c = ar < 0 ? cc : ac;
                if (r != cr || c != cc) { if (ar < 0) { ar = anchor_r; ac = anchor_c; } cr = r; cc = c; if (ar == cr && ac == cc) ar = -1; changed = 1; }
            }
            if (!down) { drag = 0; resize = -1; }
            was = down;
        } else if (hover >= 0) { hover = -1; changed = 1; }
        if (changed) draw();
        sleep_ms(15);
    }
    return 0;
}
