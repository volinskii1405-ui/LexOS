/* notepad.c - LexOS Notepad: a text editor in a window of its own.
 *
 *   run notepad.app [file...]      (Files opens text files in it)
 *
 * Several files at once, one per tab. The mouse places the cursor,
 * drags a selection (a double click takes a word), the wheel and the
 * scrollbar scroll. Keys:
 *
 *   Ctrl+N new      Ctrl+O open     Ctrl+S save     Ctrl+Shift+S save as
 *   Ctrl+W close the tab            Ctrl+Tab the next tab
 *   Ctrl+Z undo     Ctrl+Y redo     Ctrl+A everything
 *   Ctrl+C copy     Ctrl+X cut      Ctrl+V paste
 *   Ctrl+F find     Ctrl+H replace  F3 / Enter the next one
 *   Ctrl+G go to a line             Ctrl+Q quit
 *   Shift + arrows, Home, End, PgUp, PgDn: select
 *
 * C (.C .H), LexOS scripts (.HG) and web pages (.HTM .HTML) are
 * colored as they're typed: keywords, strings, comments, tags...
 *
 * The text is kept with '\n' line ends; a file that had "\r\n" is
 * written back with them. Tabs show as 4 columns. */
#include "lexos.h"

#define W 800
#define H 600
#define TAB_H 28
#define BAR_Y TAB_H
#define BAR_H 30
#define TEXT_Y (BAR_Y + BAR_H)
#define STATUS_H 22
#define GUTTER 52
#define SBW 14
#define LINE_H 16
#define CW 8
#define TABW 4
#define MAX_DOCS 8
#define DOC_MAX (512 * 1024)
#define PATH_MAX 96
#define UNDO_MAX 400
#define FIELD_MAX 80

#define C_BG      RGB(255, 255, 255)
#define C_TEXT    RGB(28, 30, 36)
#define C_GUTTER  RGB(240, 242, 246)
#define C_GUTTER_T RGB(150, 156, 168)
#define C_CURLINE RGB(246, 248, 252)
#define C_SEL     RGB(184, 212, 250)
#define C_BAR     RGB(226, 232, 242)
#define C_BAR_LO  RGB(170, 180, 198)
#define C_BTN     RGB(248, 250, 253)
#define C_HOVER   RGB(206, 222, 250)
#define C_TAB     RGB(208, 216, 230)
#define C_TAB_ON  RGB(255, 255, 255)
#define C_STATUS  RGB(236, 238, 242)
#define C_GRAY    RGB(110, 116, 128)
#define C_ACCENT  RGB(40, 90, 200)
#define C_FIND    RGB(255, 236, 150)

/* syntax colors */
#define K_TEXT 0
#define K_KEY  1
#define K_TYPE 2
#define K_STR  3
#define K_COM  4
#define K_NUM  5
#define K_PRE  6
#define K_TAG  7
#define K_ATTR 8
#define K_VAR  9
#define K_LABEL 10
static const unsigned kcolor[] = {
    RGB(28, 30, 36), RGB(0, 70, 200), RGB(0, 128, 140), RGB(170, 40, 30),
    RGB(40, 130, 50), RGB(150, 90, 0), RGB(140, 40, 150), RGB(0, 60, 170),
    RGB(170, 50, 40), RGB(0, 128, 140), RGB(200, 100, 0)
};
#define LANG_TEXT 0
#define LANG_C    1
#define LANG_HG   2
#define LANG_HTML 3

static unsigned frame[W * H];
static unsigned char glyphs[4096];

struct op {                              /* one change, for undo/redo */
    int ins;                             /* 1 inserted, 0 deleted */
    int pos, len;
    char *text;
    int group;                           /* the same group: undone together */
    int open;                            /* typing may still add to it */
};

struct doc {
    char path[PATH_MAX];                 /* "" = not saved yet */
    char name[20];
    char *t;
    int len, cap;
    int *ls;                             /* line starts */
    int nl, lcap;
    int cur, anchor;                     /* anchor -1: no selection */
    int top, left;                       /* the first line, column shown */
    int want_col;                        /* up/down keep to it */
    int dirty, crlf, lang, utf8;
    struct op undo[UNDO_MAX], redo[UNDO_MAX];
    int nundo, nredo, group;
};

static struct doc *docs[MAX_DOCS];
static int ndocs, cd;                    /* the tab in front */
#define D (docs[cd])

static char *clip;
static int cliplen;
static char status[160];
static char last_dir[PATH_MAX] = "/DESKTOP";

/* the find / replace bar */
static int findbar;                      /* 0 none, 1 find, 2 find+replace */
static int ffocus;                       /* 0 the find field, 1 replace */
static char ftext[FIELD_MAX], rtext[FIELD_MAX];

/* dialogs */
#define DLG_NONE 0
#define DLG_OPEN 1
#define DLG_SAVE 2
#define DLG_ASK  3                       /* save changes? */
#define DLG_GOTO 4
static int dlg;
static char dlg_dir[PATH_MAX], dlg_name[FIELD_MAX];
static struct lx_dirent dents[256];
static int ndents, dlg_scroll, dlg_sel = -1, dlg_fresh;
static int ask_then;                     /* after DLG_ASK: 1 close tab, 2 quit */
static int quitting;

static int hover = -1;                   /* a button under the pointer */
struct doc;
static int memchr_nl(struct doc *d);

/* ============================================================
 * little helpers
 * ============================================================ */
static int upper(int c) { return c >= 'a' && c <= 'z' ? c - 32 : c; }
static int is_alpha(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
static int is_digit(int c) { return c >= '0' && c <= '9'; }
static int is_word(int c) { return is_alpha(c) || is_digit(c) || (unsigned char)c >= 0x80; }
static void copy(char *d, const char *s, int n) { int i = 0; while (s[i] && i < n - 1) { d[i] = s[i]; i++; } d[i] = 0; }
static void append(char *d, const char *s, int n) { int l = strlen(d); copy(d + l, s, n - l); }
static void append_num(char *d, int v, int n)
{
    char b[12]; int i = 11; unsigned u = v < 0 ? -v : v;
    b[i] = 0;
    do { b[--i] = '0' + u % 10; u /= 10; } while (u);
    if (v < 0) b[--i] = '-';
    append(d, b + i, n);
}
static int ends_ci(const char *s, const char *e)
{
    int ls = strlen(s), le = strlen(e), i;
    if (le > ls) return 0;
    for (i = 0; i < le; i++) if (upper(s[ls - le + i]) != upper(e[i])) return 0;
    return 1;
}
static void say(const char *s) { copy(status, s, sizeof status); }

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
static void glyph(int x, int y, unsigned char ch, unsigned c, int bold)
{
    int r, b;
    const unsigned char *g = glyphs + ch * 16;
    if (x < 0 || x > W - 8 || y < 0 || y > H - 16) return;
    for (r = 0; r < 16; r++) {
        unsigned bits = g[r];
        unsigned *p = frame + (y + r) * W + x;
        if (bold) bits |= bits >> 1;
        for (b = 0; b < 8; b++) if (bits & (0x80 >> b)) p[b] = c;
    }
}
static void text(int x, int y, const char *t, unsigned c, int maxw)
{
    while (*t && maxw >= 8) { glyph(x, y, (unsigned char)*t++, c, 0); x += 8; maxw -= 8; }
}
static void button(int x, int y, int w, int h, const char *label, int lit)
{
    fill(x, y, w, h, C_BAR_LO);
    fill(x + 1, y + 1, w - 2, h - 2, lit ? C_HOVER : C_BTN);
    text(x + (w - 8 * (int)strlen(label)) / 2, y + (h - 16) / 2, label, C_TEXT, w);
}

/* ============================================================
 * documents: lines, edits, undo
 * ============================================================ */
static void index_lines(struct doc *d)
{
    int i, n = 1;
    for (i = 0; i < d->len; i++) if (d->t[i] == '\n') n++;
    if (n > d->lcap) {
        free(d->ls);
        d->lcap = n + 256;
        d->ls = malloc(d->lcap * sizeof(int));
    }
    d->ls[0] = 0;
    n = 1;
    for (i = 0; i < d->len; i++) if (d->t[i] == '\n') d->ls[n++] = i + 1;
    d->nl = n;
}
static int line_of(struct doc *d, int pos)
{
    int lo = 0, hi = d->nl - 1;
    while (lo < hi) {
        int mid = (lo + hi + 1) / 2;
        if (d->ls[mid] <= pos) lo = mid; else hi = mid - 1;
    }
    return lo;
}
static int line_end(struct doc *d, int l) { return l + 1 < d->nl ? d->ls[l + 1] - 1 : d->len; }
static int vcol(struct doc *d, int pos)       /* the screen column of pos */
{
    int l = line_of(d, pos), i, c = 0;
    for (i = d->ls[l]; i < pos; i++) c = d->t[i] == '\t' ? (c / TABW + 1) * TABW : c + 1;
    return c;
}
static int pos_at_col(struct doc *d, int l, int col)
{
    int i = d->ls[l], e = line_end(d, l), c = 0;
    while (i < e) {
        int n = d->t[i] == '\t' ? (c / TABW + 1) * TABW : c + 1;
        if (n > col) { if (col - c > n - col) i++; break; }
        c = n;
        i++;
    }
    return i;
}

static int ensure(struct doc *d, int more)
{
    if (d->len + more <= d->cap) return 1;
    if (d->len + more > DOC_MAX) { say("The file can't grow any bigger here (512KB)."); return 0; }
    {
        int ncap = d->len + more + 4096;
        char *n;
        if (ncap > DOC_MAX) ncap = DOC_MAX;
        n = malloc(ncap);
        if (!n) { say("Out of memory."); return 0; }
        memcpy(n, d->t, d->len);
        free(d->t);
        d->t = n;
        d->cap = ncap;
    }
    return 1;
}

static void op_free(struct op *o) { free(o->text); o->text = 0; }
static void close_undo(struct doc *d) { if (d->nundo) d->undo[d->nundo - 1].open = 0; }
static void push_undo(struct doc *d, int ins, int pos, const char *s, int n, int typing)
{
    struct op *o;
    int i;
    for (i = 0; i < d->nredo; i++) op_free(&d->redo[i]);
    d->nredo = 0;
    if (typing && d->nundo) {                    /* typing on: the same op */
        o = &d->undo[d->nundo - 1];
        if (o->open && o->ins == ins && ins && o->pos + o->len == pos && o->len < 4000 && s[0] != '\n') {
            char *nt = malloc(o->len + n);
            if (nt) {
                memcpy(nt, o->text, o->len);
                memcpy(nt + o->len, s, n);
                free(o->text);
                o->text = nt;
                o->len += n;
                return;
            }
        }
        if (o->open && !o->ins && !ins && pos + n == o->pos && o->len < 4000) {   /* backspacing */
            char *nt = malloc(o->len + n);
            if (nt) {
                memcpy(nt, s, n);
                memcpy(nt + n, o->text, o->len);
                free(o->text);
                o->text = nt;
                o->len += n;
                o->pos = pos;
                return;
            }
        }
    }
    close_undo(d);
    if (d->nundo == UNDO_MAX) {                  /* the oldest goes */
        op_free(&d->undo[0]);
        memmove(d->undo, d->undo + 1, (UNDO_MAX - 1) * sizeof(struct op));
        d->nundo--;
    }
    o = &d->undo[d->nundo++];
    o->ins = ins; o->pos = pos; o->len = n; o->group = d->group; o->open = typing;
    o->text = malloc(n ? n : 1);
    if (o->text) memcpy(o->text, s, n);
}

/* the raw edits (no undo) */
static int raw_insert(struct doc *d, int pos, const char *s, int n)
{
    if (!ensure(d, n)) return 0;
    memmove(d->t + pos + n, d->t + pos, d->len - pos);
    memcpy(d->t + pos, s, n);
    d->len += n;
    index_lines(d);
    return 1;
}
static void raw_delete(struct doc *d, int pos, int n)
{
    memmove(d->t + pos, d->t + pos + n, d->len - pos - n);
    d->len -= n;
    index_lines(d);
}

static void insert(struct doc *d, int pos, const char *s, int n, int typing)
{
    if (n <= 0) return;
    if (!raw_insert(d, pos, s, n)) return;
    push_undo(d, 1, pos, s, n, typing);
    d->dirty = 1;
}
static void delete(struct doc *d, int pos, int n, int typing)
{
    if (n <= 0) return;
    push_undo(d, 0, pos, d->t + pos, n, typing);
    raw_delete(d, pos, n);
    d->dirty = 1;
}

static int has_sel(struct doc *d) { return d->anchor >= 0 && d->anchor != d->cur; }
static int sel_a(struct doc *d) { return d->anchor < d->cur ? d->anchor : d->cur; }
static int sel_b(struct doc *d) { return d->anchor < d->cur ? d->cur : d->anchor; }
static void delete_sel(struct doc *d)
{
    int a = sel_a(d), b = sel_b(d);
    delete(d, a, b - a, 0);
    d->cur = a;
    d->anchor = -1;
}

static void undo_redo(struct doc *d, int redo)
{
    struct op *from = redo ? d->redo : d->undo, *to = redo ? d->undo : d->redo;
    int *nfrom = redo ? &d->nredo : &d->nundo, *nto = redo ? &d->nundo : &d->nredo;
    int g;
    if (!*nfrom) { say(redo ? "Nothing to redo." : "Nothing to undo."); return; }
    close_undo(d);
    g = from[*nfrom - 1].group;
    while (*nfrom && from[*nfrom - 1].group == g) {
        struct op o = from[--*nfrom];
        int ins = redo ? o.ins : !o.ins;         /* what to do now */
        if (ins) { raw_insert(d, o.pos, o.text, o.len); d->cur = o.pos + o.len; }
        else { raw_delete(d, o.pos, o.len); d->cur = o.pos; }
        o.open = 0;
        if (*nto < UNDO_MAX) to[(*nto)++] = o; else op_free(&o);
    }
    d->anchor = -1;
    d->dirty = 1;
    status[0] = 0;
}

static int lang_of(const char *name)
{
    if (ends_ci(name, ".C") || ends_ci(name, ".H")) return LANG_C;
    if (ends_ci(name, ".HG")) return LANG_HG;
    if (ends_ci(name, ".HTM") || ends_ci(name, ".HTML")) return LANG_HTML;
    return LANG_TEXT;
}

static const char *base_name(const char *p)
{
    const char *b = p;
    for (; *p; p++) if (*p == '/') b = p + 1;
    return b;
}

static void set_path(struct doc *d, const char *path)
{
    copy(d->path, path, PATH_MAX);
    copy(d->name, base_name(path), sizeof d->name);
    d->lang = lang_of(d->name);
}

static struct doc *new_doc(void)
{
    struct doc *d;
    if (ndocs >= MAX_DOCS) { say("Too many tabs: close one first (Ctrl+W)."); return 0; }
    d = calloc(1, sizeof *d);
    if (!d) { say("Out of memory."); return 0; }
    d->cap = 4096;
    d->t = malloc(d->cap);
    d->anchor = -1;
    copy(d->name, "UNTITLED.TXT", sizeof d->name);
    index_lines(d);
    docs[ndocs] = d;
    cd = ndocs++;
    return d;
}

static void free_doc(int i)
{
    struct doc *d = docs[i];
    int k;
    for (k = 0; k < d->nundo; k++) op_free(&d->undo[k]);
    for (k = 0; k < d->nredo; k++) op_free(&d->redo[k]);
    free(d->t);
    free(d->ls);
    free(d);
    memmove(docs + i, docs + i + 1, (ndocs - i - 1) * sizeof docs[0]);
    ndocs--;
    if (cd >= ndocs) cd = ndocs - 1;
}

/* UTF-8 <-> the font's code page 866 (Russian, and the Spanish letters
 * src/lang.asm puts at 0xF2...): a file in UTF-8 whose every letter
 * the font has is shown - and saved back - as UTF-8 */
static const unsigned short sp_u[] = { 0xE1, 0xE9, 0xED, 0xF3, 0xFA, 0xF1, 0xD1, 0xFC, 0xBF, 0xA1, 0xE7, 0xC7, 0xB0, 0 };
static const unsigned char sp_b[] = { 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xFC, 0xFD, 0xB5, 0xB6, 0xB7, 0xB8, 0xF8 };
static int to866(unsigned u)
{
    int i;
    if (u < 128) return u;
    if (u >= 0x410 && u <= 0x43F) return 0x80 + u - 0x410;
    if (u >= 0x440 && u <= 0x44F) return 0xE0 + u - 0x440;
    if (u == 0x401) return 0xF0;
    if (u == 0x451) return 0xF1;
    for (i = 0; sp_u[i]; i++) if (sp_u[i] == u) return sp_b[i];
    return -1;
}
static unsigned from866(unsigned char b)
{
    int i;
    if (b < 128) return b;
    if (b < 0xB0) return 0x410 + b - 0x80;
    if (b >= 0xE0 && b < 0xF0) return 0x440 + b - 0xE0;
    if (b == 0xF0) return 0x401;
    if (b == 0xF1) return 0x451;
    for (i = 0; sp_u[i]; i++) if (sp_b[i] == b) return sp_u[i];
    return '?';
}
/* t[0..n): UTF-8 that all maps? -> converted in place, its new length;
 * -1 (left as it is) if not */
static int utf8_in(char *t, int n)
{
    int i, j, any = 0;
    for (i = 0; i < n; ) {                       /* a look first */
        unsigned c = (unsigned char)t[i], u;
        int k;
        if (c < 0x80) { i++; continue; }
        if ((c & 0xE0) == 0xC0) { u = c & 0x1F; k = 1; }
        else if ((c & 0xF0) == 0xE0) { u = c & 0x0F; k = 2; }
        else return -1;
        for (i++; k--; i++) { if (i >= n || ((unsigned char)t[i] & 0xC0) != 0x80) return -1; u = u << 6 | (t[i] & 0x3F); }
        if (to866(u) < 0) return -1;
        any = 1;
    }
    if (!any) return -1;
    for (i = j = 0; i < n; ) {
        unsigned c = (unsigned char)t[i], u;
        int k;
        if (c < 0x80) { t[j++] = c; i++; continue; }
        if ((c & 0xE0) == 0xC0) { u = c & 0x1F; k = 1; } else { u = c & 0x0F; k = 2; }
        for (i++; k--; i++) u = u << 6 | (t[i] & 0x3F);
        t[j++] = (char)to866(u);
    }
    return j;
}
/* writes t[0..n) as UTF-8 (if utf8), else as it is */
static int put_text(int fd, const char *t, int n, int utf8)
{
    char buf[512];
    int i, b = 0;
    if (!utf8) return fwrite(fd, t, n) == n;
    for (i = 0; i < n; i++) {
        unsigned char c = t[i];
        if (b > 500) { if (fwrite(fd, buf, b) != b) return 0; b = 0; }
        if (c < 0x80) buf[b++] = c;
        else {
            unsigned u = from866(c);
            if (u < 0x800) { buf[b++] = 0xC0 | u >> 6; buf[b++] = 0x80 | (u & 0x3F); }
            else { buf[b++] = 0xE0 | u >> 12; buf[b++] = 0x80 | (u >> 6 & 0x3F); buf[b++] = 0x80 | (u & 0x3F); }
        }
    }
    return !b || fwrite(fd, buf, b) == b;
}

/* path -> a new tab (or the one it's in already) */
static void open_file(const char *path)
{
    int fd, n, i, j;
    struct doc *d;
    char up[PATH_MAX];
    for (i = 0; path[i] && i < PATH_MAX - 1; i++) up[i] = upper(path[i]);
    up[i] = 0;
    for (i = 0; i < ndocs; i++)
        if (!strcmp(docs[i]->path, up)) { cd = i; return; }
    /* an empty, untouched first tab: this goes in its place */
    if (ndocs == 1 && !D->path[0] && !D->len && !D->dirty) free_doc(0);
    d = new_doc();
    if (!d) return;
    set_path(d, up);
    {
        const char *b = base_name(up);
        if (b > up) { int l = b - up - 1; if (l < 1) l = 1; copy(last_dir, up, l + 1 < PATH_MAX ? l + 1 : PATH_MAX); }
    }
    fd = open(up, O_READ);
    if (fd < 0) { say("A new file: Ctrl+S saves it."); return; }
    n = fsize(fd);
    if (n > DOC_MAX - 4096) n = DOC_MAX - 4096;
    if (n > 0) {
        free(d->t);
        d->cap = n + 4096;
        d->t = malloc(d->cap);
        if (!d->t) { close(fd); say("Out of memory."); d->cap = 0; d->len = 0; return; }
        n = read(fd, d->t, n);
        if (n < 0) n = 0;
    }
    close(fd);
    for (i = j = 0; i < n; i++) {                /* \r\n -> \n (kept in mind) */
        if (d->t[i] == '\r') { if (i + 1 < n && d->t[i + 1] == '\n') d->crlf = 1; continue; }
        if (d->t[i] == 0) continue;
        d->t[j++] = d->t[i];
    }
    d->len = j;
    j = utf8_in(d->t, d->len);
    if (j >= 0) { d->len = j; d->utf8 = 1; }
    index_lines(d);
    status[0] = 0;
}

static int save_doc(struct doc *d)
{
    int fd, i, s, ok = 1;
    if (!d->path[0]) return 0;
    fd = open(d->path, O_WRITE);
    if (fd < 0) { say("Can't write it there (a read-only file, or no such folder)."); return 0; }
    if (!d->crlf) ok = put_text(fd, d->t, d->len, d->utf8);
    else
        for (s = i = 0; i <= d->len; i++)
            if (i == d->len || d->t[i] == '\n') {
                if (i > s && !put_text(fd, d->t + s, i - s, d->utf8)) ok = 0;
                if (i < d->len && fwrite(fd, "\r\n", 2) != 2) ok = 0;
                s = i + 1;
            }
    close(fd);
    if (!ok) { say("The disk is full - not all of it was saved."); return 0; }
    d->dirty = 0;
    copy(status, "Saved ", sizeof status);
    append(status, d->path, sizeof status);
    return 1;
}

/* ============================================================
 * syntax: each character's color, a line at a time, with the state
 * carried from the line before (in a comment, in a tag...)
 * ============================================================ */
static unsigned char kinds[4096];
static int bold_k[4096 / 8];

static const char *c_keys[] = { "if", "else", "for", "while", "do", "return", "break", "continue",
    "switch", "case", "default", "goto", "sizeof", "static", "const", "extern", "volatile",
    "inline", "typedef", "struct", "union", "enum", "register", "auto", 0 };
static const char *c_types[] = { "int", "char", "short", "long", "unsigned", "signed", "void",
    "float", "double", "size_t", "NULL", 0 };
static const char *hg_keys[] = { "if", "else", "end", "while", "for", "to", "step", "then", "set",
    "unset", "input", "goto", "exit", "shift", "sleep", "not", "exist", "echo", "vars", 0 };

static int in_list(const char **l, const char *s, int n, int ci)
{
    int i, k;
    for (i = 0; l[i]; i++) {
        if ((int)strlen(l[i]) != n) continue;
        for (k = 0; k < n; k++)
            if ((ci ? upper(s[k]) : s[k]) != (ci ? upper(l[i][k]) : l[i][k])) break;
        if (k == n) return 1;
    }
    return 0;
}

/* s[0..n): a line; *st: the state (C: 1 in a comment; HTML: 1 in a
 * comment, 2 in a tag, 3 in a tag's value "...", 4 in '...'); ->
 * kinds[] (for the first 4096 characters) */
static void color_line(int lang, const char *s, int n, int *st)
{
    int i = 0, k;
    int m = n < 4096 ? n : 4096;
    memset(kinds, K_TEXT, m);
    if (lang == LANG_C) {
        int first = 1;
        while (i < n) {
            int c = s[i];
            if (*st == 1) {
                int b = i;
                while (i < n && !(s[i] == '*' && i + 1 < n && s[i + 1] == '/')) i++;
                if (i < n) { i += 2; *st = 0; }
                for (k = b; k < i && k < m; k++) kinds[k] = K_COM;
                continue;
            }
            if (c == '/' && i + 1 < n && s[i + 1] == '/') { for (k = i; k < m; k++) kinds[k] = K_COM; return; }
            if (c == '/' && i + 1 < n && s[i + 1] == '*') { *st = 1; if (i < m) kinds[i] = K_COM; if (i + 1 < m) kinds[i + 1] = K_COM; i += 2; continue; }
            if (first && c == '#') {             /* #include, #define: to the end */
                for (k = i; k < m; k++) kinds[k] = K_PRE;
                for (k = i; k < n; k++)          /* (its strings, comments still) */
                    if (s[k] == '"' || s[k] == '<') { int e = k + 1; while (e < n && s[e] != (s[k] == '"' ? '"' : '>')) e++; for (; k <= e && k < m; k++) kinds[k] = K_STR; break; }
                return;
            }
            if (c != ' ' && c != '\t') first = 0;
            if (c == '"' || c == '\'') {
                int b = i++;
                while (i < n && s[i] != c) { if (s[i] == '\\') i++; i++; }
                i++;
                for (k = b; k < i && k < m; k++) kinds[k] = K_STR;
                continue;
            }
            if (is_digit(c)) {
                int b = i;
                while (i < n && (is_word(s[i]) || s[i] == '.')) i++;
                for (k = b; k < i && k < m; k++) kinds[k] = K_NUM;
                continue;
            }
            if (is_alpha(c)) {
                int b = i, kind = K_TEXT;
                while (i < n && is_word(s[i])) i++;
                if (in_list(c_keys, s + b, i - b, 0)) kind = K_KEY;
                else if (in_list(c_types, s + b, i - b, 0)) kind = K_TYPE;
                for (k = b; k < i && k < m; k++) kinds[k] = kind;
                continue;
            }
            i++;
        }
    } else if (lang == LANG_HG) {
        int b, word = 0;
        while (i < n && (s[i] == ' ' || s[i] == '\t')) i++;
        if (i < n && s[i] == '#') { for (k = i; k < m; k++) kinds[k] = K_COM; return; }
        if (i < n && s[i] == ':') { for (k = i; k < m; k++) kinds[k] = K_LABEL; return; }
        while (i < n) {
            int c = s[i];
            if (c == '$') {
                b = i++;
                if (i < n && s[i] == '{') { while (i < n && s[i] != '}') i++; i++; }
                else if (i < n && (s[i] == '#' || s[i] == '*' || s[i] == '$')) i++;
                else while (i < n && is_word(s[i])) i++;
                for (k = b; k < i && k < m; k++) kinds[k] = K_VAR;
                continue;
            }
            if (is_word(c) || c == '@') {
                int kind = K_TEXT;
                b = i;
                while (i < n && (is_word(s[i]) || s[i] == '@' || s[i] == '.')) i++;
                if (in_list(hg_keys, s + b, i - b, 1)) kind = K_KEY;
                else if (!word) kind = K_TYPE;   /* the command */
                else if (is_digit(s[b])) kind = K_NUM;
                for (k = b; k < i && k < m; k++) kinds[k] = kind;
                word++;
                continue;
            }
            if (c == '"') {
                b = i++;
                while (i < n && s[i] != '"') i++;
                i++;
                for (k = b; k < i && k < m; k++) kinds[k] = K_STR;
                continue;
            }
            if (c == '=' || c == '<' || c == '>' || c == '!' || c == '+' || c == '-' || c == '*' || c == '%' || c == '/' || c == '|')
                if (i < m) kinds[i] = K_PRE;
            i++;
        }
    } else if (lang == LANG_HTML) {
        while (i < n) {
            int c = s[i];
            if (*st == 1) {                      /* <!-- ... --> */
                int b = i;
                while (i < n && !(s[i] == '-' && i + 2 < n && s[i + 1] == '-' && s[i + 2] == '>')) i++;
                if (i < n) { i += 3; *st = 0; }
                for (k = b; k < i && k < m; k++) kinds[k] = K_COM;
                continue;
            }
            if (*st == 3 || *st == 4) {          /* a value in quotes */
                int q = *st == 3 ? '"' : '\'', b = i;
                while (i < n && s[i] != q) i++;
                if (i < n) { i++; *st = 2; }
                for (k = b; k < i && k < m; k++) kinds[k] = K_STR;
                continue;
            }
            if (*st == 2) {                      /* in a tag */
                if (c == '>') { if (i < m) kinds[i] = K_TAG; *st = 0; i++; continue; }
                if (c == '"' || c == '\'') { if (i < m) kinds[i] = K_STR; *st = c == '"' ? 3 : 4; i++; continue; }
                if (is_word(c) || c == '-' || c == ':') {
                    int b = i;
                    while (i < n && (is_word(s[i]) || s[i] == '-' || s[i] == ':')) i++;
                    for (k = b; k < i && k < m; k++) kinds[k] = K_ATTR;
                    continue;
                }
                if (c == '/' && i < m) kinds[i] = K_TAG;
                i++;
                continue;
            }
            if (c == '<' && i + 3 < n && s[i + 1] == '!' && s[i + 2] == '-' && s[i + 3] == '-') {
                *st = 1;
                for (k = i; k < i + 4 && k < m; k++) kinds[k] = K_COM;
                i += 4;
                continue;
            }
            if (c == '<') {
                int b = i++;
                if (i < n && (s[i] == '/' || s[i] == '!')) i++;
                while (i < n && (is_word(s[i]) || s[i] == '-')) i++;
                for (k = b; k < i && k < m; k++) kinds[k] = K_TAG;
                *st = 2;
                continue;
            }
            if (c == '&') {
                int b = i;
                while (i < n && s[i] != ';' && s[i] != ' ' && i - b < 10) i++;
                if (i < n && s[i] == ';') { i++; for (k = b; k < i && k < m; k++) kinds[k] = K_PRE; }
                continue;
            }
            i++;
        }
    }
    (void)bold_k;
}

/* the state at the start of line l (carried from the file's start) */
static int state_at(struct doc *d, int l)
{
    int st = 0, i;
    if (d->lang != LANG_C && d->lang != LANG_HTML) return 0;
    for (i = 0; i < l; i++) {
        int s = d->ls[i], e = line_end(d, i);
        /* a quick look first: nothing that could change it - skip */
        int k, maybe = st != 0;
        for (k = s; k < e && !maybe; k++)
            if (d->t[k] == '/' || d->t[k] == '<' || d->t[k] == '"' || d->t[k] == '\'' || d->t[k] == '-') maybe = 1;
        if (maybe) color_line(d->lang, d->t + s, e - s, &st);
    }
    return st;
}

/* ============================================================
 * the screen
 * ============================================================ */
static int text_h(void) { return H - TEXT_Y - STATUS_H - (findbar ? (findbar == 2 ? 56 : 30) : 0); }
static int rows(void) { return text_h() / LINE_H; }
static int cols(void) { return (W - GUTTER - SBW - 8) / CW; }

/* the tabs: tab i's x and width */
static int tab_w(void) { int w = ndocs ? (W - 40) / ndocs : 150; return w > 170 ? 170 : w; }

static const char *btn_label[] = { "New", "Open", "Save", "Save as", "Undo", "Redo", "Find", "Replace" };
static const int btn_x[] = { 6, 54, 110, 166, 246, 302, 370, 426 };
static const int btn_wd[] = { 44, 52, 52, 72, 52, 52, 52, 72 };
#define NBTN 8

static void draw_tabs(void)
{
    int i, w = tab_w();
    fill(0, 0, W, TAB_H, C_BAR_LO);
    for (i = 0; i < ndocs; i++) {
        int x = 2 + i * w, on = i == cd;
        char t[24];
        fill(x, on ? 3 : 5, w - 3, TAB_H - (on ? 3 : 5), on ? C_TAB_ON : C_TAB);
        if (on) fill(x, 3, w - 3, 2, C_ACCENT);
        copy(t, docs[i]->name, sizeof t);
        if (docs[i]->dirty) append(t, "*", sizeof t);
        text(x + 8, 8, t, C_TEXT, w - 32);
        text(x + w - 20, 8, "x", hover == 100 + i ? RGB(200, 40, 40) : C_GRAY, 8);
    }
    button(2 + ndocs * w + 2, 4, 26, 21, "+", hover == 99);
}

static void draw_bar(void)
{
    int i;
    fill(0, BAR_Y, W, BAR_H, C_BAR);
    fill(0, BAR_Y + BAR_H - 1, W, 1, C_BAR_LO);
    for (i = 0; i < NBTN; i++) button(btn_x[i], BAR_Y + 3, btn_wd[i], 24, btn_label[i], hover == i);
    {
        static const char *ln[] = { "Plain text", "C", "LexOS script", "HTML" };
        text(W - 8 - 8 * (int)strlen(ln[D->lang]), BAR_Y + 7, ln[D->lang], C_GRAY, 200);
    }
}

static void draw_text(void)
{
    struct doc *d = D;
    int th = text_h(), nr = rows(), nc = cols(), r, st, sa = -1, sb = -1;
    int cl = line_of(d, d->cur);
    fill(0, TEXT_Y, W, th, C_BG);
    fill(0, TEXT_Y, GUTTER - 6, th, C_GUTTER);
    if (has_sel(d)) { sa = sel_a(d); sb = sel_b(d); }
    st = state_at(d, d->top);
    for (r = 0; r < nr; r++) {
        int l = d->top + r, y = TEXT_Y + r * LINE_H, s, e, i, c = 0;
        char num[12];
        if (l >= d->nl) break;
        s = d->ls[l];
        e = line_end(d, l);
        if (l == cl && !has_sel(d)) fill(GUTTER - 6, y, W - SBW - GUTTER + 6, LINE_H, C_CURLINE);
        num[0] = 0;
        append_num(num, l + 1, sizeof num);
        text(GUTTER - 12 - 8 * (int)strlen(num), y, num, l == cl ? C_TEXT : C_GUTTER_T, 64);
        color_line(d->lang, d->t + s, e - s, &st);
        for (i = s; i <= e; i++) {
            int ch = i < e ? (unsigned char)d->t[i] : 0;
            int n = ch == '\t' ? (c / TABW + 1) * TABW : c + 1;
            int vx = c - d->left, x = GUTTER + vx * CW;
            if (i >= sa && i < sb && vx < nc && n - d->left > 0) {   /* selected */
                int w = (n - c) * CW;
                if (i == e) w = CW / 2;                           /* (its line end) */
                fill(vx < 0 ? GUTTER : x, y, vx < 0 ? (n - d->left) * CW : w, LINE_H, C_SEL);
            }
            if (i < e && ch != '\t' && ch != ' ' && vx >= 0 && vx < nc) {
                int k = i - s < 4096 ? kinds[i - s] : K_TEXT;
                glyph(x, y, ch, kcolor[k], k == K_KEY);
            }
            c = n;
            if (c - d->left > nc) break;
        }
    }
    /* the cursor */
    {
        int r2 = cl - d->top, x = GUTTER + (vcol(d, d->cur) - d->left) * CW;
        if (r2 >= 0 && r2 < nr && x >= GUTTER && x < W - SBW)
            fill(x, TEXT_Y + r2 * LINE_H, 2, LINE_H, C_TEXT);
    }
    /* the scrollbar */
    fill(W - SBW, TEXT_Y, SBW, th, C_GUTTER);
    if (d->nl > nr) {
        int tl = th * nr / d->nl, ty;
        if (tl < 24) tl = 24;
        ty = TEXT_Y + (th - tl) * d->top / (d->nl - nr);
        fill(W - SBW + 2, ty, SBW - 4, tl, C_BAR_LO);
    }
}

static void draw_field_ex(int x, int y, int w, const char *label, const char *val, int focus, int chosen)
{
    int lw = 8 * strlen(label) + 8, vl = strlen(val), show = (w - lw - 8) / 8;
    text(x, y + 4, label, C_TEXT, 200);
    fill(x + lw, y, w - lw, 24, focus ? C_ACCENT : C_BAR_LO);
    fill(x + lw + 1, y + 1, w - lw - 2, 22, C_BG);
    if (chosen && vl) fill(x + lw + 3, y + 4, 8 * (vl > show ? show : vl) + 2, 16, C_SEL);
    text(x + lw + 4, y + 4, vl > show ? val + vl - show : val, C_TEXT, w - lw - 8);
    if (focus) fill(x + lw + 4 + 8 * (vl > show ? show : vl), y + 4, 2, 16, C_TEXT);
}
static void draw_field(int x, int y, int w, const char *label, const char *val, int focus)
{
    draw_field_ex(x, y, w, label, val, focus, 0);
}

static void draw_findbar(void)
{
    int y = H - STATUS_H - (findbar == 2 ? 56 : 30);
    if (!findbar) return;
    fill(0, y, W, findbar == 2 ? 56 : 30, C_BAR);
    fill(0, y, W, 1, C_BAR_LO);
    draw_field(8, y + 3, 440, "Find:   ", ftext, ffocus == 0);
    button(456, y + 3, 64, 24, "Next", hover == 20);
    button(526, y + 3, 64, 24, "Close", hover == 21);
    if (findbar == 2) {
        draw_field(8, y + 29, 440, "Replace:", rtext, ffocus == 1);
        button(456, y + 29, 64, 24, "Replace", hover == 22);
        button(526, y + 29, 64, 24, "All", hover == 23);
    }
}

static void draw_status(void)
{
    struct doc *d = D;
    char s[160];
    int l = line_of(d, d->cur);
    fill(0, H - STATUS_H, W, STATUS_H, C_STATUS);
    fill(0, H - STATUS_H, W, 1, C_BAR_LO);
    s[0] = 0;
    append(s, "Ln ", sizeof s); append_num(s, l + 1, sizeof s);
    append(s, ", Col ", sizeof s); append_num(s, vcol(d, d->cur) + 1, sizeof s);
    if (has_sel(d)) { append(s, "  (", sizeof s); append_num(s, sel_b(d) - sel_a(d), sizeof s); append(s, " chosen)", sizeof s); }
    append(s, "   ", sizeof s);
    append_num(s, d->len, sizeof s);
    append(s, d->crlf ? " bytes, CRLF" : " bytes", sizeof s);
    if (d->utf8) append(s, ", UTF-8", sizeof s);
    text(8, H - STATUS_H + 3, s, C_GRAY, 400);
    text(W - 8 - 8 * (int)strlen(status), H - STATUS_H + 3, status, C_ACCENT, W - 420);
}

/* the dialogs, over the rest */
#define DX 140
#define DY 90
#define DW 520
#define DH 420
#define LIST_Y (DY + 64)
#define LIST_H 272
#define LIST_ROWS (LIST_H / 18)

static void draw_dialog(void)
{
    int i;
    if (!dlg) return;
    if (dlg == DLG_ASK || dlg == DLG_GOTO) {
        int x = 200, y = 220, w = 400, h = 130;
        fill(x + 4, y + 4, w, h, RGB(90, 96, 110));
        fill(x, y, w, h, C_BAR_LO);
        fill(x + 1, y + 1, w - 2, h - 2, C_BTN);
        fill(x + 1, y + 1, w - 2, 24, C_ACCENT);
        if (dlg == DLG_ASK) {
            char q[80];
            text(x + 10, y + 5, "Notepad", RGB(255, 255, 255), 200);
            copy(q, "Save the changes to ", sizeof q);
            append(q, D->name, sizeof q);
            append(q, "?", sizeof q);
            text(x + 16, y + 44, q, C_TEXT, w - 32);
            button(x + 16, y + 90, 110, 26, "Save", hover == 30);
            button(x + 136, y + 90, 110, 26, "Don't save", hover == 31);
            button(x + 256, y + 90, 110, 26, "Cancel", hover == 32);
        } else {
            text(x + 10, y + 5, "Go to line", RGB(255, 255, 255), 200);
            draw_field(x + 16, y + 44, w - 32, "Line:", dlg_name, 1);
            button(x + 136, y + 90, 110, 26, "Go", hover == 30);
            button(x + 256, y + 90, 110, 26, "Cancel", hover == 32);
        }
        return;
    }
    fill(DX + 4, DY + 4, DW, DH, RGB(90, 96, 110));
    fill(DX, DY, DW, DH, C_BAR_LO);
    fill(DX + 1, DY + 1, DW - 2, DH - 2, C_BTN);
    fill(DX + 1, DY + 1, DW - 2, 24, C_ACCENT);
    text(DX + 10, DY + 5, dlg == DLG_OPEN ? "Open a file" : "Save as", RGB(255, 255, 255), 200);
    text(DX + 12, DY + 36, "Folder:", C_GRAY, 80);
    text(DX + 76, DY + 36, dlg_dir, C_TEXT, DW - 90);
    fill(DX + 12, LIST_Y, DW - 24, LIST_H, C_BAR_LO);
    fill(DX + 13, LIST_Y + 1, DW - 26, LIST_H - 2, C_BG);
    for (i = 0; i < LIST_ROWS; i++) {
        int k = dlg_scroll + i, y = LIST_Y + 2 + i * 18;
        char sz[24];
        if (k >= ndents) break;
        if (k == dlg_sel) fill(DX + 14, y, DW - 28, 18, C_SEL);
        if (dents[k].type == LX_DIR) {
            fill(DX + 20, y + 5, 14, 9, RGB(236, 190, 40));
            fill(DX + 20, y + 3, 6, 3, RGB(236, 190, 40));
        } else {
            fill(DX + 22, y + 2, 11, 14, C_GRAY);
            fill(DX + 23, y + 3, 9, 12, RGB(255, 255, 255));
        }
        text(DX + 42, y + 1, dents[k].name, C_TEXT, 200);
        sz[0] = 0;
        if (dents[k].type == LX_DIR) append(sz, !strcmp(dents[k].name, "..") ? "" : "folder", sizeof sz);
        else { append_num(sz, dents[k].size, sizeof sz); append(sz, " bytes", sizeof sz); }
        text(DX + DW - 30 - 8 * (int)strlen(sz), y + 1, sz, C_GRAY, 200);
    }
    if (ndents > LIST_ROWS) {
        int tl = LIST_H * LIST_ROWS / ndents, ty = LIST_Y + (LIST_H - tl) * dlg_scroll / (ndents - LIST_ROWS);
        fill(DX + DW - 22, ty, 8, tl, C_BAR_LO);
    }
    draw_field_ex(DX + 12, DY + DH - 76, DW - 24, "Name:", dlg_name, 1, dlg_fresh);
    button(DX + DW - 220, DY + DH - 40, 100, 28, dlg == DLG_OPEN ? "Open" : "Save", hover == 30);
    button(DX + DW - 112, DY + DH - 40, 100, 28, "Cancel", hover == 32);
}

static void redraw(void)
{
    draw_tabs();
    draw_bar();
    draw_text();
    draw_findbar();
    draw_status();
    draw_dialog();
    gfx_blit(frame);
}

/* the cursor kept on screen */
static void show_cursor(void)
{
    struct doc *d = D;
    int l = line_of(d, d->cur), c = vcol(d, d->cur), nr = rows(), nc = cols();
    if (l < d->top) d->top = l;
    if (l >= d->top + nr) d->top = l - nr + 1;
    if (c < d->left) d->left = c > 8 ? c - 8 : 0;
    if (c >= d->left + nc) d->left = c - nc + 8;
    if (d->top < 0) d->top = 0;
}
static void clamp_top(void)
{
    struct doc *d = D;
    int mx = d->nl - rows();
    if (d->top > mx) d->top = mx;
    if (d->top < 0) d->top = 0;
}

/* ============================================================
 * editing commands
 * ============================================================ */
static void do_copy(int cut)
{
    struct doc *d = D;
    int a, b;
    if (!has_sel(d)) {                           /* nothing chosen: the line */
        int l = line_of(d, d->cur);
        a = d->ls[l];
        b = l + 1 < d->nl ? d->ls[l + 1] : d->len;
    } else { a = sel_a(d); b = sel_b(d); }
    free(clip);
    cliplen = b - a;
    clip = malloc(cliplen + 1);
    if (!clip) { cliplen = 0; return; }
    memcpy(clip, d->t + a, cliplen);
    if (cut) {
        d->group++;
        delete(d, a, b - a, 0);
        d->cur = a;
        d->anchor = -1;
        d->group++;
    }
}
static void do_paste(void)
{
    struct doc *d = D;
    if (!cliplen) return;
    d->group++;
    if (has_sel(d)) delete_sel(d);
    insert(d, d->cur, clip, cliplen, 0);
    d->cur += cliplen;
    d->anchor = -1;
    d->group++;
}
static void type_text(const char *s, int n)
{
    struct doc *d = D;
    if (has_sel(d)) { d->group++; delete_sel(d); insert(d, d->cur, s, n, 0); d->group++; }
    else insert(d, d->cur, s, n, 1);
    d->cur += n;
    d->anchor = -1;
}
static void newline(void)
{
    struct doc *d = D;
    char buf[128];
    int l, i, n = 1;
    if (has_sel(d)) { d->group++; delete_sel(d); }
    l = line_of(d, d->cur);
    buf[0] = '\n';
    for (i = d->ls[l]; i < d->cur && (d->t[i] == ' ' || d->t[i] == '\t') && n < 120; i++) buf[n++] = d->t[i];
    close_undo(d);
    d->group++;
    insert(d, d->cur, buf, n, 0);
    d->cur += n;
    d->anchor = -1;
    d->group++;
}

/* find: from the cursor on (wrapping round), not minding capitals */
static int find_from(struct doc *d, int from, const char *f)
{
    int n = strlen(f), i, k, tries;
    if (!n) return -1;
    for (tries = 0; tries < 2; tries++) {
        for (i = from; i + n <= d->len; i++) {
            for (k = 0; k < n; k++) if (upper(d->t[i + k]) != upper(f[k])) break;
            if (k == n) return i;
        }
        from = 0;
    }
    return -1;
}
static int find_next(void)
{
    struct doc *d = D;
    int at = find_from(d, d->cur, ftext);
    if (at < 0) { say("Not found."); return 0; }
    d->anchor = at;
    d->cur = at + strlen(ftext);
    status[0] = 0;
    show_cursor();
    return 1;
}
static int sel_is_found(struct doc *d)
{
    int n = strlen(ftext), k, a = sel_a(d);
    if (!has_sel(d) || sel_b(d) - a != n) return 0;
    for (k = 0; k < n; k++) if (upper(d->t[a + k]) != upper(ftext[k])) return 0;
    return 1;
}
static void replace_one(void)
{
    struct doc *d = D;
    if (sel_is_found(d)) {
        int a = sel_a(d);
        d->group++;
        delete(d, a, sel_b(d) - a, 0);
        insert(d, a, rtext, strlen(rtext), 0);
        d->group++;
        d->cur = a + strlen(rtext);
        d->anchor = -1;
    }
    find_next();
}
static void replace_all(void)
{
    struct doc *d = D;
    int at = 0, n = strlen(ftext), rn = strlen(rtext), count = 0, k;
    if (!n) return;
    d->group++;
    for (;;) {
        int i, found = -1;
        for (i = at; i + n <= d->len && found < 0; i++) {
            for (k = 0; k < n; k++) if (upper(d->t[i + k]) != upper(ftext[k])) break;
            if (k == n) found = i;
        }
        if (found < 0) break;
        delete(d, found, n, 0);
        insert(d, found, rtext, rn, 0);
        at = found + rn;
        count++;
    }
    d->group++;
    d->anchor = -1;
    if (d->cur > d->len) d->cur = d->len;
    status[0] = 0;
    append(status, "Replaced: ", sizeof status);
    append_num(status, count, sizeof status);
}

/* ============================================================
 * the dialogs
 * ============================================================ */
static void list_dir(void)
{
    int i, j;
    struct lx_dirent e;
    ndents = 0;
    if (strcmp(dlg_dir, "/")) { memset(&dents[0], 0, sizeof dents[0]); copy(dents[0].name, "..", 16); dents[0].type = LX_DIR; ndents = 1; }
    for (i = 0; ndents < 256 && readdir(dlg_dir, i, &e) == 0; i++) dents[ndents++] = e;
    for (i = 1; i < ndents; i++) {               /* folders first, by name */
        struct lx_dirent t = dents[i];
        int tk = t.type == LX_DIR ? 0 : 1;
        if (!strcmp(t.name, "..")) continue;
        for (j = i; j > 0 && strcmp(dents[j - 1].name, "..") != 0; j--) {
            int pk = dents[j - 1].type == LX_DIR ? 0 : 1;
            if (pk < tk || (pk == tk && strcmp(dents[j - 1].name, t.name) <= 0)) break;
            dents[j] = dents[j - 1];
        }
        dents[j] = t;
    }
    dlg_scroll = 0;
    dlg_sel = -1;
}
static void open_dialog(int kind)
{
    dlg = kind;
    copy(dlg_dir, last_dir, PATH_MAX);
    dlg_name[0] = 0;
    if (kind == DLG_SAVE) {
        if (D->path[0]) {
            const char *b = base_name(D->path);
            int l = b - D->path - 1;
            if (l < 1) l = 1;
            copy(dlg_dir, D->path, l + 1);
        }
        copy(dlg_name, D->name, FIELD_MAX);
        dlg_fresh = 1;
    }
    list_dir();
}
static void join(char *out, const char *dir, const char *name)
{
    copy(out, dir, PATH_MAX);
    if (strcmp(dir, "/")) append(out, "/", PATH_MAX);
    append(out, name, PATH_MAX);
}
static void enter_dir(const char *name)
{
    if (!strcmp(name, "..")) {
        int l = strlen(dlg_dir);
        while (l > 1 && dlg_dir[l - 1] != '/') l--;
        if (l > 1) l--;
        dlg_dir[l] = 0;
    } else {
        char p[PATH_MAX];
        join(p, dlg_dir, name);
        copy(dlg_dir, p, PATH_MAX);
    }
    list_dir();
}
static void finish_close(void);
static void dialog_ok(void)
{
    char p[PATH_MAX];
    int i;
    if (dlg == DLG_GOTO) {
        int l = atoi(dlg_name);
        dlg = 0;
        if (l < 1) l = 1;
        if (l > D->nl) l = D->nl;
        D->cur = D->ls[l - 1];
        D->anchor = -1;
        D->top = l - 1 - rows() / 2;
        clamp_top();
        return;
    }
    if (dlg == DLG_ASK) {                        /* Save */
        if (!D->path[0]) { open_dialog(DLG_SAVE); return; }
        dlg = 0;
        if (save_doc(D)) finish_close();
        return;
    }
    if (!dlg_name[0]) return;
    for (i = 0; i < ndents; i++)                 /* a folder's name: into it */
        if (dents[i].type == LX_DIR && !strcmp(dents[i].name, dlg_name)) { enter_dir(dlg_name); dlg_name[0] = 0; return; }
    if (dlg_name[0] == '/') copy(p, dlg_name, PATH_MAX);
    else join(p, dlg_dir, dlg_name);
    for (i = 0; p[i]; i++) p[i] = upper(p[i]);
    copy(last_dir, dlg_dir, PATH_MAX);
    if (dlg == DLG_OPEN) { dlg = 0; open_file(p); return; }
    /* save as */
    set_path(D, p);
    dlg = 0;
    if (save_doc(D) && ask_then) finish_close();
}

static void finish_close(void)
{
    int then = ask_then;
    ask_then = 0;
    if (then == 2) { quitting = 1; return; }
    free_doc(cd);
    if (!ndocs) new_doc();
}
static void close_tab(int i)
{
    cd = i;
    if (D->dirty) { dlg = DLG_ASK; ask_then = 1; return; }
    ask_then = 1;
    finish_close();
}
static void quit(void)
{
    int i;
    for (i = 0; i < ndocs; i++)
        if (docs[i]->dirty) { cd = i; dlg = DLG_ASK; ask_then = 2; return; }
    quitting = 1;
}
static void save(int as)
{
    if (as || !D->path[0]) { open_dialog(DLG_SAVE); return; }
    save_doc(D);
}

/* ============================================================
 * the keyboard
 * ============================================================ */
static void field_key(char *f, int ch)
{
    int l = strlen(f);
    if (ch == 8) { if (l) f[l - 1] = 0; }
    else if (ch >= 32 && l < FIELD_MAX - 1) { f[l] = ch; f[l + 1] = 0; }
}

static void move_to(int pos, int shift)
{
    struct doc *d = D;
    close_undo(d);
    if (shift) { if (d->anchor < 0) d->anchor = d->cur; }
    else d->anchor = -1;
    if (pos < 0) pos = 0;
    if (pos > d->len) pos = d->len;
    d->cur = pos;
}

static void key(int ch, int sc)
{
    struct doc *d = D;
    int ctrl = keydown(KEY_CTRL), shift = keydown(KEY_LSHIFT) || keydown(KEY_RSHIFT);
    if (ch >= 1 && ch <= 26 && sc != 0x0E && sc != 0x0F && sc != 0x1C) ctrl = 1;   /* Ctrl+letter (keymode) */
    int l = line_of(d, d->cur);

    if (dlg) {
        if (ch == 27) { dlg = 0; if (ask_then && !quitting) ask_then = 0; return; }
        if (dlg == DLG_ASK) {
            if (ch == 13) dialog_ok();
            return;
        }
        if (ch == 13) { dialog_ok(); return; }
        if (dlg == DLG_GOTO) { if (ch == 8 || is_digit(ch)) field_key(dlg_name, ch); return; }
        if (sc == 0x48 && !ch) { if (dlg_sel > 0) dlg_sel--; }
        else if (sc == 0x50 && !ch) { if (dlg_sel < ndents - 1) dlg_sel++; }
        else {
            if (dlg_fresh && (ch == 8 || ch >= 32)) dlg_name[0] = 0;   /* (chosen: replaced) */
            dlg_fresh = 0;
            field_key(dlg_name, ch);
            return;
        }
        dlg_fresh = 0;
        if (dlg_sel >= 0) {
            copy(dlg_name, dents[dlg_sel].name, FIELD_MAX);
            if (dlg_sel < dlg_scroll) dlg_scroll = dlg_sel;
            if (dlg_sel >= dlg_scroll + LIST_ROWS) dlg_scroll = dlg_sel - LIST_ROWS + 1;
        }
        return;
    }

    if (ctrl) {
        switch (sc) {
        case 0x1E: d->anchor = 0; d->cur = d->len; return;              /* A */
        case 0x2E: do_copy(0); say("Copied."); return;                  /* C */
        case 0x2D: do_copy(1); break;                                   /* X */
        case 0x2F: do_paste(); break;                                   /* V */
        case 0x2C: undo_redo(d, 0); break;                              /* Z */
        case 0x15: undo_redo(d, 1); break;                              /* Y */
        case 0x1F: save(shift); return;                                 /* S */
        case 0x18: open_dialog(DLG_OPEN); return;                       /* O */
        case 0x31: new_doc(); return;                                   /* N */
        case 0x11: close_tab(cd); return;                               /* W */
        case 0x10: quit(); return;                                      /* Q */
        case 0x21: findbar = findbar ? findbar : 1; ffocus = 0;         /* F */
            if (has_sel(d) && sel_b(d) - sel_a(d) < FIELD_MAX && !memchr_nl(d)) { int n = sel_b(d) - sel_a(d); memcpy(ftext, d->t + sel_a(d), n); ftext[n] = 0; }
            return;
        case 0x23: findbar = 2; ffocus = ftext[0] ? 1 : 0; return;      /* H */
        case 0x22: dlg = DLG_GOTO; dlg_name[0] = 0; return;             /* G */
        case 0x0F: cd = (cd + 1) % ndocs; return;                       /* Tab */
        case 0x47: move_to(0, shift); break;                            /* Home */
        case 0x4F: move_to(d->len, shift); break;                       /* End */
        case 0x4B: {                                                    /* a word left */
            int p = d->cur;
            while (p > 0 && !is_word(d->t[p - 1])) p--;
            while (p > 0 && is_word(d->t[p - 1])) p--;
            move_to(p, shift);
            break;
        }
        case 0x4D: {                                                    /* a word right */
            int p = d->cur;
            while (p < d->len && is_word(d->t[p])) p++;
            while (p < d->len && !is_word(d->t[p])) p++;
            move_to(p, shift);
            break;
        }
        default: return;
        }
        show_cursor();
        return;
    }

    if (findbar && (ffocus >= 0) && ch && ch != 27 && sc != 0x3D && !(ch == 9 && findbar == 1)) {
        /* typing into the find bar */
        if (ch == 13) { if (ffocus == 1) replace_one(); else find_next(); return; }
        if (ch == 9) { ffocus = !ffocus; return; }
        field_key(ffocus ? rtext : ftext, ch);
        return;
    }
    if (ch == 27) { if (findbar) { findbar = 0; ffocus = 0; clamp_top(); } else d->anchor = -1; return; }
    if (sc == 0x3D) { find_next(); return; }                            /* F3 */

    if (!ch) {
        int c;
        switch (sc) {
        case 0x4B: if (has_sel(d) && !shift) move_to(sel_a(d), 0); else move_to(d->cur - 1, shift); d->want_col = -1; break;
        case 0x4D: if (has_sel(d) && !shift) move_to(sel_b(d), 0); else move_to(d->cur + 1, shift); d->want_col = -1; break;
        case 0x48: case 0x50: case 0x49: case 0x51: {
            int step = sc == 0x48 ? -1 : sc == 0x50 ? 1 : sc == 0x49 ? -(rows() - 1) : rows() - 1;
            int nl2 = l + step;
            if (d->want_col < 0) d->want_col = vcol(d, d->cur);
            if (nl2 < 0) { move_to(0, shift); break; }
            if (nl2 >= d->nl) { move_to(d->len, shift); break; }
            c = d->want_col;
            move_to(pos_at_col(d, nl2, c), shift);
            d->want_col = c;
            if (sc == 0x49 || sc == 0x51) { d->top += step; clamp_top(); }
            break;
        }
        case 0x47: {                                                    /* Home: past the indent first */
            int s = d->ls[l], p = s;
            while (p < line_end(d, l) && (d->t[p] == ' ' || d->t[p] == '\t')) p++;
            move_to(d->cur == p ? s : p, shift);
            d->want_col = -1;
            break;
        }
        case 0x4F: move_to(line_end(d, l), shift); d->want_col = -1; break;
        case 0x53:                                                      /* Delete */
            if (has_sel(d)) { d->group++; delete_sel(d); d->group++; }
            else if (d->cur < d->len) delete(d, d->cur, 1, 0);
            break;
        default: return;
        }
        show_cursor();
        return;
    }
    d->want_col = -1;
    if (ch == 8) {
        if (has_sel(d)) { d->group++; delete_sel(d); d->group++; }
        else if (d->cur > 0) { delete(d, d->cur - 1, 1, 1); d->cur--; }
    } else if (ch == 13) newline();
    else if (ch == 9) {
        if (has_sel(d) && line_of(d, sel_a(d)) != line_of(d, sel_b(d))) {   /* indent the lines */
            int a = line_of(d, sel_a(d)), b = line_of(d, sel_b(d) - 1), i;
            d->group++;
            for (i = b; i >= a; i--) {
                int s = d->ls[i];
                if (shift) {
                    int n = 0;
                    while (n < TABW && s + n < d->len && d->t[s + n] == ' ') n++;
                    delete(d, s, n, 0);
                } else insert(d, s, "    ", TABW, 0);
            }
            d->group++;
            d->anchor = d->ls[a];
            d->cur = line_end(d, b);
        } else {
            int c = vcol(d, d->cur), n = TABW - c % TABW;
            type_text("    ", n);
        }
    } else if ((unsigned char)ch >= 32) {
        char c = ch;
        type_text(&c, 1);
    }
    show_cursor();
}

/* ============================================================
 * the mouse
 * ============================================================ */
static int pos_at(int mx, int my)
{
    struct doc *d = D;
    int l = d->top + (my - TEXT_Y) / LINE_H, col;
    if (my < TEXT_Y) l = d->top - 1;
    if (l < 0) return 0;
    if (l >= d->nl) return d->len;
    col = (mx - GUTTER + CW / 2) / CW + d->left;
    if (col < 0) col = 0;
    return pos_at_col(d, l, col);
}

static int button_at(int mx, int my)
{
    int i, w = tab_w();
    if (dlg) {
        if (dlg == DLG_ASK || dlg == DLG_GOTO) {
            int x = 200, y = 220;
            if (my >= y + 90 && my < y + 116) {
                if (mx >= x + 16 && mx < x + 126 && dlg == DLG_ASK) return 30;
                if (mx >= x + 136 && mx < x + 246) return dlg == DLG_ASK ? 31 : 30;
                if (mx >= x + 256 && mx < x + 366) return 32;
            }
            return -1;
        }
        if (my >= DY + DH - 40 && my < DY + DH - 12) {
            if (mx >= DX + DW - 220 && mx < DX + DW - 120) return 30;
            if (mx >= DX + DW - 112 && mx < DX + DW - 12) return 32;
        }
        return -1;
    }
    if (my < TAB_H) {
        if (mx >= 2 + ndocs * w + 2 && mx < 2 + ndocs * w + 28) return 99;
        i = (mx - 2) / w;
        if (i >= 0 && i < ndocs) {
            int x = 2 + i * w;
            if (mx >= x + w - 24 && mx < x + w - 6) return 100 + i;
            return 200 + i;
        }
        return -1;
    }
    if (my >= BAR_Y + 3 && my < BAR_Y + 27)
        for (i = 0; i < NBTN; i++) if (mx >= btn_x[i] && mx < btn_x[i] + btn_wd[i]) return i;
    if (findbar) {
        int y = H - STATUS_H - (findbar == 2 ? 56 : 30);
        if (my >= y + 3 && my < y + 27) {
            if (mx >= 456 && mx < 520) return 20;
            if (mx >= 526 && mx < 590) return 21;
            if (mx < 448) return 24;
        }
        if (findbar == 2 && my >= y + 29 && my < y + 53) {
            if (mx >= 456 && mx < 520) return 22;
            if (mx >= 526 && mx < 590) return 23;
            if (mx < 448) return 25;
        }
    }
    return -1;
}

static void press(int b)
{
    switch (b) {
    case 0: new_doc(); break;
    case 1: open_dialog(DLG_OPEN); break;
    case 2: save(0); break;
    case 3: save(1); break;
    case 4: undo_redo(D, 0); show_cursor(); break;
    case 5: undo_redo(D, 1); show_cursor(); break;
    case 6: findbar = findbar ? findbar : 1; ffocus = 0; break;
    case 7: findbar = 2; ffocus = 0; break;
    case 20: find_next(); break;
    case 21: findbar = 0; clamp_top(); break;
    case 22: replace_one(); break;
    case 23: replace_all(); break;
    case 24: ffocus = 0; break;
    case 25: ffocus = 1; break;
    case 30: dialog_ok(); break;
    case 31: dlg = 0; D->dirty = 0; finish_close(); break;   /* don't save */
    case 32: dlg = 0; if (!quitting) ask_then = 0; break;
    case 99: new_doc(); break;
    default:
        if (b >= 200) { cd = b - 200; break; }
        if (b >= 100) close_tab(b - 100);
    }
}

/* ============================================================ */
/* the selection has a line end in it */
static int memchr_nl(struct doc *d)
{
    int i;
    for (i = sel_a(d); i < sel_b(d); i++) if (d->t[i] == '\n') return 1;
    return 0;
}

int main(int argc, char **argv)
{
    int m[4], was_down = 0, drag = 0, sdrag = 0, i;
    unsigned last_click = 0;
    int last_pos = -1;
    if (gfx_mode_ex(W, H, 32) < 0) { puts("notepad: needs 800x600 in 32 bits\n"); return 1; }
    font(glyphs);
    keymode(1);
    new_doc();
    for (i = 1; i < argc; i++) open_file(argv[i]);
    if (argc < 2) say("Ctrl+O opens a file, Ctrl+S saves.");
    redraw();
    while (!quitting) {
        int k = pollkey(), changed = 0, over;
        while (k) {
            key(k & 0xFF, (k >> 8) & 0xFF);
            changed = 1;
            if (quitting) break;
            k = pollkey();
        }
        if (quitting) break;
        over = mouse(m);
        if (m[3]) {
            if (dlg == DLG_OPEN || dlg == DLG_SAVE) {
                dlg_scroll += m[3] * 3;
                if (dlg_scroll > ndents - LIST_ROWS) dlg_scroll = ndents - LIST_ROWS;
                if (dlg_scroll < 0) dlg_scroll = 0;
            } else { D->top += m[3] * 3; clamp_top(); }
            changed = 1;
        }
        if (over) {
            int down = m[2] & 1, mx = m[0], my = m[1];
            int hb = button_at(mx, my);
            if (hb != hover) { hover = hb; changed = 1; }
            if (down && !was_down) {
                unsigned now = millis();
                int dbl = now - last_click < 400;
                last_click = now;
                if (hb >= 0) { press(hb); changed = 1; }
                else if (dlg == DLG_OPEN || dlg == DLG_SAVE) {
                    if (mx >= DX + 12 && mx < DX + DW - 12 && my >= LIST_Y && my < LIST_Y + LIST_H) {
                        int k2 = dlg_scroll + (my - LIST_Y - 2) / 18;
                        if (k2 >= 0 && k2 < ndents) {
                            if (dbl && k2 == dlg_sel) {
                                if (dents[k2].type == LX_DIR) { enter_dir(dents[k2].name); dlg_name[0] = 0; }
                                else { copy(dlg_name, dents[k2].name, FIELD_MAX); dialog_ok(); }
                            } else {
                                dlg_sel = k2;
                                if (dents[k2].type != LX_DIR) copy(dlg_name, dents[k2].name, FIELD_MAX);
                            }
                        }
                    }
                    changed = 1;
                } else if (!dlg && my >= TEXT_Y && my < TEXT_Y + text_h()) {
                    if (mx >= W - SBW) sdrag = 1;
                    else {
                        struct doc *d = D;
                        int p = pos_at(mx, my);
                        close_undo(d);
                        if (dbl && p == last_pos) {                 /* a word */
                            int a = p, b = p;
                            while (a > 0 && is_word(d->t[a - 1])) a--;
                            while (b < d->len && is_word(d->t[b])) b++;
                            d->anchor = a; d->cur = b;
                        } else {
                            if (keydown(KEY_LSHIFT) || keydown(KEY_RSHIFT)) { if (d->anchor < 0) d->anchor = d->cur; }
                            else d->anchor = p;
                            d->cur = p;
                            drag = 1;
                        }
                        d->want_col = -1;
                        last_pos = p;
                        if (findbar) ffocus = -1;
                    }
                    changed = 1;
                }
            }
            if (down && sdrag) {
                int th = text_h(), nr = rows();
                if (D->nl > nr) { D->top = (my - TEXT_Y) * (D->nl - nr) / (th > 1 ? th : 1); clamp_top(); changed = 1; }
            } else if (down && drag) {
                int p = pos_at(mx, my);
                if (p != D->cur) {
                    D->cur = p;
                    if (my < TEXT_Y) { D->top--; clamp_top(); }
                    if (my >= TEXT_Y + text_h()) { D->top++; clamp_top(); }
                    changed = 1;
                }
            }
            if (!down) { drag = 0; sdrag = 0; }
            was_down = down;
        } else {
            if (hover >= 0) { hover = -1; changed = 1; }
            was_down = 0; drag = 0; sdrag = 0;
        }
        if (changed) redraw();
        sleep_ms(15);
    }
    gfx_mode(0);
    return 0;
}
