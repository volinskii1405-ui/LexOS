/* calc.c - LexOS Calculator: a window with buttons, Standard and
 * Scientific.
 *
 *   run calc.app
 *
 * What's pressed (or typed) builds an expression - 12+3×(4−1) - shown
 * above; its value, as it stands, below it, big. = (Enter) makes it
 * the value to go on from. Operators have their usual precedence;
 * a missing ")" at the end is taken as there.
 *
 * Keys: 0-9 . + - * / ^ ( ) % !  Enter or = the result, Backspace the
 * last one, Esc or Delete clears; s c t sin cos tan, l ln, g log,
 * r square root, p pi, e e. Tab switches Standard / Scientific.
 *
 * Numbers are doubles, shown with up to 12 digits (from 10^15 or
 * below 10^-9 as 1.2345e+20). */
#include "lexos.h"

#define W 400
#define H 470
#define DISP_H 100
#define TABS_Y DISP_H
#define TABS_H 28
#define GRID_Y (TABS_Y + TABS_H + 6)
#define EXPR_MAX 120

#define C_BG      RGB(243, 245, 249)
#define C_DISP    RGB(255, 255, 255)
#define C_TEXT    RGB(28, 30, 36)
#define C_GRAY    RGB(120, 126, 138)
#define C_LINE    RGB(200, 206, 218)
#define C_KEY     RGB(255, 255, 255)
#define C_OP      RGB(228, 234, 246)
#define C_FN      RGB(236, 238, 243)
#define C_EQ      RGB(40, 90, 200)
#define C_EQ_HI   RGB(64, 112, 222)
#define C_HOVER   RGB(206, 222, 250)
#define C_TAB_ON  RGB(255, 255, 255)
#define C_ERR     RGB(200, 50, 50)

static unsigned frame[W * H];
static unsigned char glyphs[4096];

/* our own glyphs, in codes the text never uses: x, divide, pi, squared */
#define G_TIMES 1
#define G_DIV   2
#define G_PI    3
#define G_SQ    4
#define G_ROOT  0xFB                             /* (code page 866's own) */
static const unsigned char g_times[16] = { 0, 0, 0, 0, 0x82, 0x44, 0x28, 0x10, 0x28, 0x44, 0x82, 0, 0, 0, 0, 0 };
static const unsigned char g_div[16]   = { 0, 0, 0, 0x10, 0x10, 0, 0, 0xFE, 0, 0, 0x10, 0x10, 0, 0, 0, 0 };
static const unsigned char g_pi[16]    = { 0, 0, 0, 0, 0, 0xFE, 0x6C, 0x6C, 0x6C, 0x6C, 0x6C, 0x6C, 0x6E, 0, 0, 0 };
static const unsigned char g_sq[16]    = { 0, 0x70, 0x88, 0x10, 0x20, 0x40, 0xF8, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

static char expr[EXPR_MAX];              /* as typed: * / P (pi) R (root) */
static char shown[64];                   /* its value, or what's wrong */
static char last_expr[EXPR_MAX + 4];     /* after =, what it was */
static int just_done;                    /* = pressed: a digit starts anew */
static int sci, deg = 1, hover = -1;
static double memory;
static int has_memory;

/* ============================================================
 * drawing
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
static void glyph(int x, int y, unsigned char ch, unsigned c, int k)   /* k: scale */
{
    int r, b;
    const unsigned char *g = glyphs + ch * 16;
    for (r = 0; r < 16 * k; r++) {
        unsigned bits = g[r / k];
        if (y + r < 0 || y + r >= H) continue;
        for (b = 0; b < 8 * k; b++)
            if (bits & (0x80 >> (b / k)) && x + b >= 0 && x + b < W) frame[(y + r) * W + x + b] = c;
    }
}
static unsigned char disp_code(char c)
{
    if (c == '*') return G_TIMES;
    if (c == '/') return G_DIV;
    if (c == 'P') return G_PI;
    if (c == 'R') return G_ROOT;
    return (unsigned char)c;
}
static void text(int x, int y, const char *t, unsigned c, int k)
{
    while (*t) { glyph(x, y, (unsigned char)*t++, c, k); x += 8 * k; }
}
static void expr_text(int x, int y, const char *t, unsigned c)      /* * / P R as signs */
{
    while (*t) { glyph(x, y, disp_code(*t++), c, 1); x += 8; }
}
static int text_w(const char *t, int k) { return 8 * k * strlen(t); }

/* ============================================================
 * numbers
 * ============================================================ */
static int is_bad(double v) { return v != v || v - v != 0; }
static void copy(char *d, const char *s, int n) { int i = 0; while (s[i] && i < n - 1) { d[i] = s[i]; i++; } d[i] = 0; }

/* v -> text: up to 12 significant digits, no trailing zeros */
static void fmt(double v, char *out)
{
    char dig[20];
    int e = 0, i, n = 0, neg = v < 0, sig = 12;
    double m;
    if (is_bad(v)) { strcpy(out, "Error"); return; }
    if (neg) v = -v;
    if (v == 0) { strcpy(out, "0"); return; }
    m = v;
    while (m >= 10) { m /= 10; e++; }
    while (m < 1) { m *= 10; e--; }
    {                                            /* rounded to sig digits */
        double half = 5;
        for (i = 0; i < sig; i++) half /= 10;
        m += half;
        if (m >= 10) { m /= 10; e++; }
    }
    for (i = 0; i < sig; i++) { int d = (int)m; if (d > 9) d = 9; dig[i] = '0' + d; m = (m - d) * 10; }
    while (sig > 1 && dig[sig - 1] == '0') sig--;
    if (neg) out[n++] = '-';
    if (e >= 15 || e < -9) {                     /* 1.2345e+20 */
        out[n++] = dig[0];
        if (sig > 1) { out[n++] = '.'; for (i = 1; i < sig && i < 10; i++) out[n++] = dig[i]; }
        out[n++] = 'e';
        out[n++] = e < 0 ? '-' : '+';
        if (e < 0) e = -e;
        if (e >= 100) out[n++] = '0' + e / 100;
        if (e >= 10) out[n++] = '0' + e / 10 % 10;
        out[n++] = '0' + e % 10;
    } else if (e < 0) {                          /* 0.00123 */
        out[n++] = '0'; out[n++] = '.';
        for (i = -1; i > e; i--) out[n++] = '0';
        for (i = 0; i < sig; i++) out[n++] = dig[i];
    } else {
        for (i = 0; i <= e; i++) out[n++] = i < sig ? dig[i] : '0';
        if (sig > e + 1) { out[n++] = '.'; for (i = e + 1; i < sig; i++) out[n++] = dig[i]; }
    }
    out[n] = 0;
}

/* ============================================================
 * the expression: read by recursive descent
 * ============================================================ */
static const char *ep;
static int eerr;
static double e_sum(void);
static double e_unary(void);

static int at_word(const char *w)
{
    int n = strlen(w);
    if (memcmp(ep, w, n)) return 0;
    ep += n;
    return 1;
}
static double to_rad(double a) { return deg ? a * M_PI / 180 : a; }
static double from_rad(double a) { return deg ? a * 180 / M_PI : a; }
static double fact(double v)
{
    double r = 1;
    int i, n = (int)v;
    if (v < 0 || v > 170 || n != v) { eerr = 1; return 0; }
    for (i = 2; i <= n; i++) r *= i;
    return r;
}
static double e_number(void)
{
    double v = 0, scale = 1;
    int any = 0;
    while (*ep >= '0' && *ep <= '9') { v = v * 10 + (*ep++ - '0'); any = 1; }
    if (*ep == '.') {
        ep++;
        while (*ep >= '0' && *ep <= '9') { scale /= 10; v += (*ep++ - '0') * scale; any = 1; }
    }
    if (!any) { eerr = 1; return 0; }
    if (*ep == 'e' && (ep[1] == '+' || ep[1] == '-') && ep[2] >= '0' && ep[2] <= '9') {   /* 1e+20 */
        int neg = ep[1] == '-', x = 0;
        ep += 2;
        while (*ep >= '0' && *ep <= '9') x = x * 10 + (*ep++ - '0');
        while (x--) v = neg ? v / 10 : v * 10;
    }
    return v;
}
static double e_paren(void)                      /* ( expr ) - the ")" may be missing at the end */
{
    double v;
    if (*ep != '(') { eerr = 1; return 0; }
    ep++;
    v = e_sum();
    if (*ep == ')') ep++;
    else if (*ep) eerr = 1;
    return v;
}
static double e_primary(void)
{
    double v;
    if ((*ep >= '0' && *ep <= '9') || *ep == '.') return e_number();
    if (*ep == '(') return e_paren();
    if (*ep == 'P') { ep++; return M_PI; }
    if (*ep == 'R') { ep++; v = e_unary(); if (v < 0) eerr = 1; return sqrt(v); }
    if (at_word("sin")) return sin(to_rad(e_paren()));
    if (at_word("cos")) return cos(to_rad(e_paren()));
    if (at_word("tan")) {
        double a = to_rad(e_paren()), c = cos(a);
        if (fabs(c) < 1e-15) { eerr = 1; return 0; }
        return sin(a) / c;
    }
    if (at_word("asin")) { v = e_paren(); if (v < -1 || v > 1) eerr = 1; return from_rad(atan2(v, sqrt(1 - v * v))); }
    if (at_word("acos")) { v = e_paren(); if (v < -1 || v > 1) eerr = 1; return from_rad(atan2(sqrt(1 - v * v), v)); }
    if (at_word("atan")) return from_rad(atan(e_paren()));
    if (at_word("ln")) { v = e_paren(); if (v <= 0) eerr = 1; return log(v); }
    if (at_word("log")) { v = e_paren(); if (v <= 0) eerr = 1; return log(v) / log(10.0); }
    if (at_word("exp")) return exp(e_paren());
    if (*ep == 'e') { ep++; return exp(1.0); }
    eerr = 1;
    return 0;
}
static double e_postfix(void)
{
    double v = e_primary();
    for (;;) {
        if (*ep == '!') { ep++; v = fact(v); }
        else if (*ep == '%') { ep++; v /= 100; }
        else return v;
    }
}
static double ipow(double b, double x)
{
    int n = (int)x, neg = n < 0, i;
    double r = 1;
    if (n == x && n > -1000 && n < 1000) {
        if (neg) n = -n;
        for (i = 0; i < n; i++) r *= b;
        return neg ? 1 / r : r;
    }
    if (b < 0) { eerr = 1; return 0; }
    if (b == 0) return 0;
    return pow(b, x);
}
static double e_power(void)
{
    double v = e_postfix();
    if (*ep == '^') { ep++; v = ipow(v, e_unary()); }
    return v;
}
static double e_unary(void)
{
    if (*ep == '-') { ep++; return -e_unary(); }
    if (*ep == '+') { ep++; return e_unary(); }
    return e_power();
}
static int starts_operand(char c)
{
    return (c >= '0' && c <= '9') || c == '.' || c == '(' || c == 'P' || c == 'R' ||
           (c >= 'a' && c <= 'z');
}
static double e_product(void)
{
    double v = e_unary();
    for (;;) {
        if (*ep == '*') { ep++; v *= e_unary(); }
        else if (*ep == '/') {
            double d;
            ep++;
            d = e_unary();
            if (d == 0) eerr = 1; else v /= d;
        } else if (starts_operand(*ep)) v *= e_unary();       /* 2P, 3(4+1) */
        else return v;
    }
}
static double e_sum(void)
{
    double v = e_product();
    for (;;) {
        if (*ep == '+') { ep++; v += e_product(); }
        else if (*ep == '-') { ep++; v -= e_product(); }
        else return v;
    }
}
/* -> 0 and *v, or -1 (not a whole expression yet, or no value) */
static int evaluate(const char *s, double *v)
{
    ep = s; eerr = 0;
    if (!*s) return -1;
    *v = e_sum();
    while (*ep == ')') ep++;
    if (eerr || *ep || is_bad(*v)) return -1;
    return 0;
}
static void update_shown(void)
{
    double v;
    if (!expr[0]) { strcpy(shown, "0"); return; }
    if (evaluate(expr, &v) == 0) fmt(v, shown);
    else shown[0] = 0;
}

/* ============================================================
 * building the expression
 * ============================================================ */
static char last_char(void) { int l = strlen(expr); return l ? expr[l - 1] : 0; }
static int ends_operand(void)
{
    char c = last_char();
    return (c >= '0' && c <= '9') || c == '.' || c == ')' || c == 'P' || c == '!' || c == '%' ||
           (c == 'e' && strlen(expr) >= 1);
}
static void add(const char *s)
{
    int l = strlen(expr), n = strlen(s);
    if (l + n < EXPR_MAX) { memcpy(expr + l, s, n + 1); }
}
static void start_fresh(int keep)                /* after =: keep the result, or not */
{
    if (!just_done) return;
    just_done = 0;
    last_expr[0] = 0;
    if (!keep) expr[0] = 0;
}
static void backspace(void)
{
    static const char *words[] = { "asin(", "acos(", "atan(", "sin(", "cos(", "tan(", "log(", "exp(", "ln(" };
    int l = strlen(expr), i;
    start_fresh(1);
    for (i = 0; i < 9; i++) {
        int n = strlen(words[i]);
        if (l >= n && !memcmp(expr + l - n, words[i], n)) { expr[l - n] = 0; return; }
    }
    if (l) expr[l - 1] = 0;
}
static void digit(char c)
{
    char s[2] = { c, 0 };
    start_fresh(0);
    if (c == '.') {                              /* one point per number */
        int l = strlen(expr);
        while (l > 0 && expr[l - 1] >= '0' && expr[l - 1] <= '9') l--;
        if (l > 0 && expr[l - 1] == '.') return;
        if (!(last_char() >= '0' && last_char() <= '9')) add("0");
    }
    add(s);
}
static void op(char c)
{
    char s[2] = { c, 0 };
    char l = last_char();
    start_fresh(1);
    if (!expr[0] && c != '-') add(shown[0] && strcmp(shown, "Error") ? shown : "0");
    if ((l == '+' || l == '-' || l == '*' || l == '/' || l == '^') && c != '-') expr[strlen(expr) - 1] = 0;
    add(s);
}
static void func(const char *f)                  /* sin( ... */
{
    start_fresh(0);
    add(f);
}
static void wrap(const char *pre, const char *post)   /* 1/(x), R(x): the whole thing */
{
    char t[EXPR_MAX + 8];
    start_fresh(1);
    if (!expr[0]) { add(pre); return; }
    copy(t, pre, sizeof t);
    if (strlen(t) + strlen(expr) + strlen(post) + 2 >= EXPR_MAX) return;
    strcpy(t + strlen(t), "(");
    strcpy(t + strlen(t), expr);
    strcpy(t + strlen(t), ")");
    strcpy(t + strlen(t), post);
    strcpy(expr, t);
}
static void equals(void)
{
    double v;
    if (!expr[0]) return;
    if (evaluate(expr, &v) < 0) { strcpy(shown, "Error"); return; }
    copy(last_expr, expr, EXPR_MAX);
    strcpy(last_expr + strlen(last_expr), " =");
    fmt(v, shown);
    copy(expr, shown, EXPR_MAX);
    just_done = 1;
}
static void clear_all(void) { expr[0] = 0; last_expr[0] = 0; just_done = 0; }
static void negate(void)
{
    start_fresh(1);
    if (!expr[0]) return;
    if (expr[0] == '-' && expr[1] == '(' && last_char() == ')') {     /* -(x) -> x */
        int l = strlen(expr);
        memmove(expr, expr + 2, l - 3);
        expr[l - 3] = 0;
        return;
    }
    wrap("-", "");
}
static double current(void) { double v; return evaluate(expr, &v) == 0 ? v : 0; }
static void put_number(double v)
{
    char s[40];
    fmt(v, s);
    start_fresh(0);
    if (ends_operand()) add("*");
    if (s[0] == '-') { add("("); add(s); add(")"); } else add(s);
}

/* ============================================================
 * the buttons
 * ============================================================ */
struct key { const char *label; int id; int kind; };           /* kind: 0 digit, 1 op, 2 fn, 3 = */
enum {
    K_0 = '0', K_DOT = '.', K_ADD = '+', K_SUB = '-', K_MUL = '*', K_DIV = '/',
    K_EQ = 200, K_C, K_CE, K_BS, K_NEG, K_PCT, K_INV, K_SQ, K_SQRT, K_POW, K_LP, K_RP,
    K_SIN, K_COS, K_TAN, K_ASIN, K_ACOS, K_ATAN, K_LN, K_LOG, K_EXP, K_TEN, K_FACT, K_PI, K_E,
    K_MC, K_MR, K_MADD, K_MSUB, K_DEG
};
static const struct key std_keys[7 * 4] = {
    { "MC", K_MC, 2 }, { "MR", K_MR, 2 }, { "M+", K_MADD, 2 }, { "M-", K_MSUB, 2 },
    { "%", K_PCT, 1 }, { "CE", K_CE, 1 }, { "C", K_C, 1 }, { "<-", K_BS, 1 },
    { "1/x", K_INV, 1 }, { "x\4", K_SQ, 1 }, { "\373x", K_SQRT, 1 }, { "\2", K_DIV, 1 },
    { "7", '7', 0 }, { "8", '8', 0 }, { "9", '9', 0 }, { "\1", K_MUL, 1 },
    { "4", '4', 0 }, { "5", '5', 0 }, { "6", '6', 0 }, { "-", K_SUB, 1 },
    { "1", '1', 0 }, { "2", '2', 0 }, { "3", '3', 0 }, { "+", K_ADD, 1 },
    { "+/-", K_NEG, 1 }, { "0", '0', 0 }, { ".", K_DOT, 0 }, { "=", K_EQ, 3 },
};
static const struct key sci_keys[7 * 6] = {
    { "DEG", K_DEG, 2 }, { "MR", K_MR, 2 }, { "M+", K_MADD, 2 }, { "%", K_PCT, 1 }, { "C", K_C, 1 }, { "<-", K_BS, 1 },
    { "sin", K_SIN, 2 }, { "asin", K_ASIN, 2 }, { "(", K_LP, 1 }, { ")", K_RP, 1 }, { "n!", K_FACT, 1 }, { "\2", K_DIV, 1 },
    { "cos", K_COS, 2 }, { "acos", K_ACOS, 2 }, { "7", '7', 0 }, { "8", '8', 0 }, { "9", '9', 0 }, { "\1", K_MUL, 1 },
    { "tan", K_TAN, 2 }, { "atan", K_ATAN, 2 }, { "4", '4', 0 }, { "5", '5', 0 }, { "6", '6', 0 }, { "-", K_SUB, 1 },
    { "ln", K_LN, 2 }, { "e^x", K_EXP, 2 }, { "1", '1', 0 }, { "2", '2', 0 }, { "3", '3', 0 }, { "+", K_ADD, 1 },
    { "log", K_LOG, 2 }, { "10^x", K_TEN, 2 }, { "+/-", K_NEG, 1 }, { "0", '0', 0 }, { ".", K_DOT, 0 }, { "=", K_EQ, 3 },
    { "x^y", K_POW, 2 }, { "x\4", K_SQ, 2 }, { "\373x", K_SQRT, 2 }, { "\3", K_PI, 2 }, { "e", K_E, 2 }, { "1/x", K_INV, 2 },
};
static const struct key *keys(void) { return sci ? sci_keys : std_keys; }
static int nkeys(void) { return sci ? 42 : 28; }
static int ncols(void) { return sci ? 6 : 4; }
static void key_rect(int i, int *x, int *y, int *w, int *h)
{
    int cols = ncols(), rows = nkeys() / cols, gw = W - 12, gh = H - GRID_Y - 6;
    *w = gw / cols - 4; *h = gh / rows - 4;
    *x = 6 + (i % cols) * (gw / cols) + 2;
    *y = GRID_Y + (i / cols) * (gh / rows) + 2;
}
static int key_at(int mx, int my)
{
    int i, x, y, w, h;
    if (my >= TABS_Y && my < TABS_Y + TABS_H) {
        if (mx >= 8 && mx < 8 + 110) return 1000;
        if (mx >= 122 && mx < 122 + 110) return 1001;
        return -1;
    }
    for (i = 0; i < nkeys(); i++) {
        key_rect(i, &x, &y, &w, &h);
        if (mx >= x && mx < x + w && my >= y && my < y + h) return i;
    }
    return -1;
}

static void press_id(int id)
{
    switch (id) {
    case K_EQ: equals(); break;
    case K_C: clear_all(); break;
    case K_CE: {                                 /* the last number */
        int l = strlen(expr);
        start_fresh(1);
        while (l > 0 && ((expr[l - 1] >= '0' && expr[l - 1] <= '9') || expr[l - 1] == '.')) l--;
        expr[l] = 0;
        break;
    }
    case K_BS: backspace(); break;
    case K_NEG: negate(); break;
    case K_PCT: start_fresh(1); if (ends_operand()) add("%"); break;
    case K_INV: wrap("1/", ""); break;
    case K_SQ: start_fresh(1); if (ends_operand()) add("^2"); break;
    case K_SQRT: wrap("R", ""); break;
    case K_POW: op('^'); break;
    case K_LP: start_fresh(0); if (ends_operand()) add("*"); add("("); break;
    case K_RP: start_fresh(1); add(")"); break;
    case K_SIN: func("sin("); break;
    case K_COS: func("cos("); break;
    case K_TAN: func("tan("); break;
    case K_ASIN: func("asin("); break;
    case K_ACOS: func("acos("); break;
    case K_ATAN: func("atan("); break;
    case K_LN: func("ln("); break;
    case K_LOG: func("log("); break;
    case K_EXP: func("exp("); break;
    case K_TEN: start_fresh(0); if (ends_operand()) add("*"); add("10^"); break;
    case K_FACT: start_fresh(1); if (ends_operand()) add("!"); break;
    case K_PI: start_fresh(0); if (ends_operand()) add("*"); add("P"); break;
    case K_E: start_fresh(0); if (ends_operand()) add("*"); add("e"); break;
    case K_MC: memory = 0; has_memory = 0; break;
    case K_MR: if (has_memory) put_number(memory); break;
    case K_MADD: memory += current(); has_memory = 1; break;
    case K_MSUB: memory -= current(); has_memory = 1; break;
    case K_DEG: deg = !deg; break;
    case K_ADD: case K_SUB: case K_MUL: case K_DIV: op((char)id); break;
    default:
        if ((id >= '0' && id <= '9') || id == '.') digit((char)id);
    }
    update_shown();
}

static void draw(void)
{
    int i, x, y, w, h, k;
    char e[EXPR_MAX + 8];
    const char *show;
    fill(0, 0, W, H, C_BG);
    /* the display: what's typed, then its value, big */
    fill(0, 0, W, DISP_H, C_DISP);
    fill(0, DISP_H - 1, W, 1, C_LINE);
    if (has_memory) text(10, 8, "M", C_GRAY, 1);
    if (sci) text(W - 34, 8, deg ? "DEG" : "RAD", C_GRAY, 1);
    copy(e, just_done ? last_expr : expr, sizeof e);
    show = e;
    while (text_w(show, 1) > W - 60) show++;
    expr_text(W - 12 - text_w(show, 1), 30, show, C_GRAY);
    show = shown[0] ? shown : "";
    k = text_w(show, 3) <= W - 24 ? 3 : 2;
    if (text_w(show, k) > W - 24) k = 1;
    text(W - 12 - text_w(show, k), DISP_H - 12 - 16 * k, show, strcmp(show, "Error") ? C_TEXT : C_ERR, k);
    /* Standard / Scientific */
    for (i = 0; i < 2; i++) {
        int tx = 8 + i * 114, on = sci == i;
        fill(tx, TABS_Y + 4, 110, TABS_H - 4, on ? C_TAB_ON : hover == 1000 + i ? C_HOVER : C_BG);
        if (on) fill(tx, TABS_Y + TABS_H - 2, 110, 2, C_EQ);
        text(tx + (110 - text_w(i ? "Scientific" : "Standard", 1)) / 2, TABS_Y + 8, i ? "Scientific" : "Standard", on ? C_TEXT : C_GRAY, 1);
    }
    fill(0, TABS_Y + TABS_H, W, 1, C_LINE);
    /* the keys */
    for (i = 0; i < nkeys(); i++) {
        const struct key *kk = &keys()[i];
        unsigned bgc = kk->kind == 0 ? C_KEY : kk->kind == 1 ? C_OP : kk->kind == 2 ? C_FN : C_EQ;
        const char *lab = kk->id == K_DEG ? (deg ? "DEG" : "RAD") : kk->label;
        key_rect(i, &x, &y, &w, &h);
        if (hover == i) bgc = kk->kind == 3 ? C_EQ_HI : C_HOVER;
        fill(x, y, w, h, C_LINE);
        fill(x + 1, y + 1, w - 2, h - 2, bgc);
        k = kk->kind == 0 && !sci ? 2 : 1;
        text(x + (w - text_w(lab, k)) / 2, y + (h - 16 * k) / 2, lab, kk->kind == 3 ? RGB(255, 255, 255) : C_TEXT, k);
    }
    gfx_blit(frame);
}

static void key_in(int c, int sc)
{
    if (c == 13 || c == '=') press_id(K_EQ);
    else if (c == 8) press_id(K_BS);
    else if (c == 27 || sc == 0x53) press_id(K_C);
    else if (c == 9) sci = !sci;
    else if ((c >= '0' && c <= '9') || c == '.') press_id(c);
    else if (c == ',') press_id('.');
    else if (c == '+' || c == '-' || c == '*' || c == '/') press_id(c);
    else if (c == '^') press_id(K_POW);
    else if (c == '(') press_id(K_LP);
    else if (c == ')') press_id(K_RP);
    else if (c == '%') press_id(K_PCT);
    else if (c == '!') press_id(K_FACT);
    else if (c == 's') press_id(K_SIN);
    else if (c == 'c') press_id(K_COS);
    else if (c == 't') press_id(K_TAN);
    else if (c == 'l') press_id(K_LN);
    else if (c == 'g') press_id(K_LOG);
    else if (c == 'r') press_id(K_SQRT);
    else if (c == 'p') press_id(K_PI);
    else if (c == 'e') press_id(K_E);
}

int main(void)
{
    int m[4], was = 0;
    if (gfx_mode_ex(W, H, 32) < 0) { puts("calc: needs 400x470 in 32 bits\n"); return 1; }
    font(glyphs);
    memcpy(glyphs + G_TIMES * 16, g_times, 16);
    memcpy(glyphs + G_DIV * 16, g_div, 16);
    memcpy(glyphs + G_PI * 16, g_pi, 16);
    memcpy(glyphs + G_SQ * 16, g_sq, 16);
    update_shown();
    draw();
    for (;;) {
        int k = pollkey(), changed = 0;
        while (k) {
            key_in(k & 0xFF, (k >> 8) & 0xFF);
            changed = 1;
            k = pollkey();
        }
        if (mouse(m)) {
            int down = m[2] & 1, hk = key_at(m[0], m[1]);
            if (hk != hover) { hover = hk; changed = 1; }
            if (down && !was && hk >= 0) {
                if (hk >= 1000) sci = hk - 1000;
                else press_id(keys()[hk].id);
                hover = key_at(m[0], m[1]);
                changed = 1;
            }
            was = down;
        } else {
            if (hover >= 0) { hover = -1; changed = 1; }
            was = 0;
        }
        if (changed) draw();
        sleep_ms(15);
    }
    return 0;
}
