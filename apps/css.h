/* css.h - the CSS LexOS Web understands: style sheets read a character
 * at a time (from <style>, or a <link>ed file as it comes) into rules,
 * matched against dom.h's tree, each element's look computed from
 * them (the cascade: the browser's own sheet, the page's HTML
 * attributes, the page's rules and style="...", !important last; what's
 * inherited from the parent).
 *
 *   css_reset();  css_begin(sheet); css_feed(c) ...  css_end();
 *   css_compute(root);           every element's dn[].cs
 *
 * Selectors: tag, *, .class, #id, [attr], [attr=v] (~= |= ^= $= *=),
 * :first-child, :last-child, :only-child, :nth-child(an+b),
 * :nth-last-child, :nth-of-type, :first/last-of-type, :not(), :is(),
 * :where(), :root, :empty, :link, :checked, :disabled - and the
 * descendant, >, + and ~ combinators. :hover, :focus and the like
 * never match (nothing's hovered when a page is laid out); rules for
 * ::before/::after are left out.
 *
 * Properties: display, position (+ top/right/bottom/left/inset),
 * float, clear, visibility, color, background(-color/-image), font
 * (-size/-weight/-style), text-align, text-decoration, text-transform,
 * text-indent, white-space, width, height, min-/max-, margin, padding,
 * border (widths, colors), box-sizing, overflow, opacity, list-style,
 * vertical-align, z-index, flex (direction, wrap, grow, shrink, basis,
 * flow), order, justify-content, align-items/-self/-content, gap,
 * grid-template-columns/-areas, grid-column/-row/-area; custom
 * properties and var(), calc()/min()/max()/clamp(); em, rem, %, vw,
 * vh, px, pt. @media is judged as a screen 800 wide and 600 high,
 * @supports as yes, other @-blocks (@font-face, @keyframes) left out. */
#ifndef CSS_H
#define CSS_H
#include "lexos.h"

#define CSS_VW 800
#define CSS_VH 600

/* ================================================================
 * computed styles
 * ================================================================ */
enum { D_INLINE, D_BLOCK, D_NONE, D_INLINE_BLOCK, D_FLEX, D_INLINE_FLEX, D_GRID, D_INLINE_GRID, D_LIST_ITEM,
       D_TABLE, D_INLINE_TABLE, D_ROW, D_CELL, D_ROW_GROUP, D_CAPTION, D_CONTENTS, D_COLUMN };
enum { P_STATIC, P_RELATIVE, P_ABSOLUTE, P_FIXED, P_STICKY };
enum { F_NONE, F_LEFT, F_RIGHT };
enum { WS_NORMAL, WS_PRE, WS_NOWRAP, WS_PRE_WRAP, WS_PRE_LINE };
enum { TA_LEFT, TA_CENTER, TA_RIGHT, TA_JUSTIFY };
enum { TT_NONE, TT_UPPER, TT_LOWER, TT_CAP };
enum { LS_DISC, LS_CIRCLE, LS_SQUARE, LS_DECIMAL, LS_NONE, LS_LALPHA, LS_UALPHA, LS_LROMAN, LS_UROMAN };
enum { FD_ROW, FD_ROW_REV, FD_COL, FD_COL_REV };
enum { J_START, J_END, J_CENTER, J_BETWEEN, J_AROUND, J_EVENLY, J_STRETCH, J_BASELINE, J_AUTO };
enum { L_UNSET, L_AUTO, L_LEN, L_NONE, L_CONTENT };
enum { OV_VISIBLE, OV_HIDDEN, OV_AUTO };
enum { VA_BASE, VA_TOP, VA_MIDDLE, VA_BOTTOM };

struct clen { float px, pct; unsigned char kind; };
struct cvar { int name, val; struct cvar *next; };       /* (custom properties, inherited) */
struct cstyle {
    unsigned char display, position, flt, clear, hidden, ws, talign, ttrans, bold, ital, under, strike, lstyle,
        overflow, boxsz, fdir, fwrap, justify, aitems, aself, acontent, valign, has_bg, sronly, nowrap_text, has_color;
    short fsize, order, zindex;
    unsigned color, bg, eff_bg;                           /* (eff_bg: what's behind it, to mix colors over) */
    float grow, shrink, opacity;
    struct clen w, h, minw, maxw, minh, maxh, m[4], p[4], pos[4], basis, rgap, cgap, tindent;
    short bw[4];
    unsigned bc[4];
    int grid_cols, grid_rows, grid_areas, grid_area;      /* (strings in css_pool, 0: none) */
    short gc_s, gc_e, gr_s, gr_e;                         /* grid lines: 1.., -1 the last; span: >1000 */
    int bg_url;
    struct cvar *vars;
};

/* ================================================================
 * the rules
 * ================================================================ */
struct ccomp {                                            /* one compound selector */
    int tag, id, cls, nattr, attr, nots, iss;             /* (classes, attributes: in css_ci[] / css_ca[]) */
    unsigned pseudo;
    unsigned char ncls, comb, nth_kind, any;
    short nth_a, nth_b;
};
#define PS_FIRST  1
#define PS_LAST   2
#define PS_ONLY   4
#define PS_ROOT   8
#define PS_EMPTY  16
#define PS_LINK   32
#define PS_CHECKED 64
#define PS_DISABLED 128
#define PS_ENABLED 256
#define PS_NEVER  512
#define PS_FIRST_T 1024
#define PS_LAST_T 2048
#define PS_ONLY_T 4096
struct cattr { int name, val; unsigned char op, icase; };
struct csel { int first, n; unsigned spec; };             /* compounds [first, first + n), left to right */
struct crule { int sel, decl, ndecl, order, next; unsigned spec; unsigned char origin; };
struct cdecl { int prop, val; unsigned char imp; };

static struct ccomp *css_cc;  static int css_ncc, css_cc_cap;
static int *css_ci;           static int css_nci, css_ci_cap;          /* class strings; :not/:is selector lists */
static struct cattr *css_ca;  static int css_nca, css_ca_cap;
static struct csel *css_sel;  static int css_nsel, css_sel_cap;
static struct crule *css_rules; static int css_nrules, css_rules_cap;
static struct cdecl *css_dcl; static int css_ndcl, css_dcl_cap;
static char *css_pool;        static int css_npool, css_pool_cap;
#define CSS_BUCKETS 2048
static int css_bucket[CSS_BUCKETS], css_tag_bucket[512], css_any_bucket;
static int css_order, css_sheet, css_origin = 1;
static char css_imports[4][1024];
static char css_base[1024];                               /* the sheet's own address (its url()s are from there) */
static void (*css_url_fix)(const char *base, const char *href, char *out);
static int css_nimports;

#define CSS_GROW(arr, n, cap, need) \
    (((n) + (need) <= (cap)) ? 1 : css_grow((void **)&(arr), &(cap), (n) + (need), sizeof *(arr)))
static int css_grow(void **a, int *cap, int need, int size)
{
    int nc = *cap ? *cap * 2 : 256;
    void *na;
    while (nc < need) nc *= 2;
    na = realloc(*a, (size_t)nc * size);
    if (!na) return 0;
    *a = na;
    *cap = nc;
    return 1;
}
static int css_lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
static int css_str(const char *s, int n)
{
    int at;
    if (!CSS_GROW(css_pool, css_npool, css_pool_cap, n + 2)) return 0;
    if (!css_npool) css_pool[css_npool++] = 0;
    at = css_npool;
    memcpy(css_pool + at, s, n);
    css_pool[at + n] = 0;
    css_npool += n + 1;
    return at;
}
static int css_starts(const char *s, const char *p)
{
    while (*p) if (css_lower((unsigned char)*s++) != css_lower((unsigned char)*p++)) return 0;
    return 1;
}
static const char *css_find(const char *s, const char *w)
{
    int n = strlen(w);
    for (; *s; s++) if (!memcmp(s, w, n)) return s;
    return 0;
}
static const char *css_chr(const char *s, int c)
{
    for (; *s; s++) if (*s == c) return s;
    return 0;
}
static int css_isname(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c >= 0x80 || c == '\\'; }
static unsigned css_hashs(const char *s, int n, int kind)
{
    unsigned h = 2166136261u ^ kind;
    while (n--) h = (h ^ (unsigned char)*s++) * 16777619u;
    return h & (CSS_BUCKETS - 1);
}

static void css_reset(void)
{
    int i;
    atoms_init();                                        /* (the known tags' atoms first) */
    css_ncc = css_nci = css_nca = css_nsel = css_nrules = css_ndcl = css_npool = 0;
    for (i = 0; i < CSS_BUCKETS; i++) css_bucket[i] = -1;
    for (i = 0; i < 512; i++) css_tag_bucket[i] = -1;
    css_any_bucket = -1;
    css_order = 0;
    css_sheet = 0;
    css_nimports = 0;
}

/* ---- selectors ---- */
static const char *css_sel_list(const char *s, const char *e, int *first, int *n);
/* a name (ident, maybe escaped) -> its length in s, unescaped into out */
static int css_ident(const char *s, const char *e, char *out, int max)
{
    int k = 0;
    const char *p = s;
    while (p < e && css_isname((unsigned char)*p)) {
        if (*p == '\\' && p + 1 < e) {
            p++;
            if (*p >= '0' && *p <= '9') { while (p < e && ((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f'))) p++; if (p < e && *p == ' ') p++; continue; }
        }
        if (k < max - 1) out[k++] = *p;
        p++;
    }
    out[k] = 0;
    return p - s;
}
static int css_nth(const char *s, short *a, short *b)
{
    int na = 0, nb = 0, sign = 1, have_n = 0, num = 0, any = 0;
    while (*s == ' ') s++;
    if (css_starts(s, "odd")) { *a = 2; *b = 1; return 1; }
    if (css_starts(s, "even")) { *a = 2; *b = 0; return 1; }
    if (*s == '-') { sign = -1; s++; } else if (*s == '+') s++;
    while (*s >= '0' && *s <= '9') { num = num * 10 + *s++ - '0'; any = 1; }
    if (*s == 'n' || *s == 'N') {
        have_n = 1;
        na = any ? sign * num : sign;
        s++;
        while (*s == ' ') s++;
        sign = 1;
        if (*s == '-') { sign = -1; s++; } else if (*s == '+') s++;
        while (*s == ' ') s++;
        num = 0;
        while (*s >= '0' && *s <= '9') num = num * 10 + *s++ - '0';
        nb = sign * num;
    } else nb = sign * num;
    (void)have_n;
    *a = na; *b = nb;
    return 1;
}
/* one compound: s..e -> css_cc; specificity added to *spec; 0 if not kept */
static const char *css_compound2(const char *s, const char *e, struct ccomp *c, unsigned *spec, int *lcls, struct cattr *lat);
static const char *css_compound(const char *s, const char *e, struct ccomp *c, unsigned *spec)
{
    int lcls[16], k;                                      /* (its classes and attributes: together at its */
    struct cattr lat[8];                                  /*  end - a :not()'s own go in before them) */
    const char *r = css_compound2(s, e, c, spec, lcls, lat);
    if (!r) return 0;
    if (!CSS_GROW(css_ci, css_nci, css_ci_cap, c->ncls) || !CSS_GROW(css_ca, css_nca, css_ca_cap, c->nattr)) return 0;
    c->cls = css_nci;
    for (k = 0; k < c->ncls; k++) css_ci[css_nci++] = lcls[k];
    c->attr = css_nca;
    for (k = 0; k < c->nattr; k++) css_ca[css_nca++] = lat[k];
    return r;
}
static const char *css_compound2(const char *s, const char *e, struct ccomp *c, unsigned *spec, int *lcls, struct cattr *lat)
{
    char name[96];
    memset(c, 0, sizeof *c);
    c->nots = c->iss = -1;
    if (s < e && *s == '*') { s++; c->any = 1; }
    else if (s < e && css_isname((unsigned char)*s)) {
        int l = css_ident(s, e, name, sizeof name), k;
        for (k = 0; name[k]; k++) name[k] = css_lower(name[k]);
        c->tag = atom_get(name, strlen(name), 1);
        s += l;
        *spec += 1;
    }
    while (s < e) {
        if (*s == '.') {
            int l = css_ident(s + 1, e, name, sizeof name);
            if (!l || c->ncls >= 16) return 0;
            lcls[c->ncls++] = css_str(name, strlen(name));
            s += 1 + l;
            *spec += 1 << 10;
        } else if (*s == '#') {
            int l = css_ident(s + 1, e, name, sizeof name);
            if (!l) return 0;
            c->id = css_str(name, strlen(name));
            s += 1 + l;
            *spec += 1 << 20;
        } else if (*s == '[') {
            struct cattr a;
            const char *q = s + 1;
            int l, k;
            memset(&a, 0, sizeof a);
            while (q < e && *q == ' ') q++;
            l = css_ident(q, e, name, sizeof name);
            for (k = 0; name[k]; k++) name[k] = css_lower(name[k]);
            a.name = atom_get(name, strlen(name), 1);
            q += l;
            while (q < e && *q == ' ') q++;
            if (q < e && *q != ']') {
                char v[256];
                int vn = 0;
                a.op = *q == '=' ? '=' : *q;
                q += *q == '=' ? 1 : 2;
                while (q < e && *q == ' ') q++;
                if (q < e && (*q == '"' || *q == '\'')) {
                    char qc = *q++;
                    while (q < e && *q != qc) { if (vn < 255) v[vn++] = *q; q++; }
                    if (q < e) q++;
                } else while (q < e && *q != ']' && *q != ' ') { if (vn < 255) v[vn++] = *q; q++; }
                v[vn] = 0;
                while (q < e && *q == ' ') q++;
                if (q < e && (*q == 'i' || *q == 'I')) { a.icase = 1; q++; }
                else if (q < e && (*q == 's' || *q == 'S')) q++;
                a.val = css_str(v, vn);
            } else a.op = 'E';
            while (q < e && *q != ']') q++;
            s = q < e ? q + 1 : e;
            if (c->nattr >= 8) return 0;
            lat[c->nattr++] = a;
            *spec += 1 << 10;
        } else if (*s == ':') {
            int l, el = s + 1 < e && s[1] == ':';
            const char *arg = 0, *arge = 0;
            s += el ? 2 : 1;
            l = css_ident(s, e, name, sizeof name);
            s += l;
            if (s < e && *s == '(') {                     /* its argument, to the ) that matches */
                int depth = 1;
                arg = ++s;
                while (s < e && depth) { if (*s == '(') depth++; else if (*s == ')') depth--; if (depth) s++; }
                arge = s;
                if (s < e) s++;
            }
            {
                int k;
                for (k = 0; name[k]; k++) name[k] = css_lower(name[k]);
            }
            if (el || !strcmp(name, "before") || !strcmp(name, "after") || !strcmp(name, "first-line") ||
                !strcmp(name, "first-letter") || !strcmp(name, "selection") || !strcmp(name, "placeholder") ||
                !strcmp(name, "marker") || !strcmp(name, "backdrop") || name[0] == '-') {
                if (el && (!strcmp(name, "-webkit-scrollbar") || name[0] == '-')) return 0;
                return 0;                                 /* (pseudo-elements: the rule's not used) */
            }
            *spec += 1 << 10;
            if (!strcmp(name, "first-child")) c->pseudo |= PS_FIRST;
            else if (!strcmp(name, "last-child")) c->pseudo |= PS_LAST;
            else if (!strcmp(name, "only-child")) c->pseudo |= PS_ONLY;
            else if (!strcmp(name, "first-of-type")) c->pseudo |= PS_FIRST_T;
            else if (!strcmp(name, "last-of-type")) c->pseudo |= PS_LAST_T;
            else if (!strcmp(name, "only-of-type")) c->pseudo |= PS_ONLY_T;
            else if (!strcmp(name, "root")) c->pseudo |= PS_ROOT;
            else if (!strcmp(name, "empty")) c->pseudo |= PS_EMPTY;
            else if (!strcmp(name, "link") || !strcmp(name, "any-link")) c->pseudo |= PS_LINK;
            else if (!strcmp(name, "checked")) c->pseudo |= PS_CHECKED;
            else if (!strcmp(name, "disabled")) c->pseudo |= PS_DISABLED;
            else if (!strcmp(name, "enabled")) c->pseudo |= PS_ENABLED;
            else if (!strcmp(name, "nth-child") || !strcmp(name, "nth-last-child") || !strcmp(name, "nth-of-type") ||
                     !strcmp(name, "nth-last-of-type")) {
                char t[64];
                int k = 0;
                while (arg && arg < arge && k < 63 && *arg != ' ' + 0x100) { t[k++] = *arg++; }
                t[k] = 0;
                {                                         /* ("2n+1 of .x": the of part not kept) */
                    char *o = t;
                    while (*o && !(o[0] == 'o' && o[1] == 'f' && o[2] == ' ')) o++;
                    *o = 0;
                }
                css_nth(t, &c->nth_a, &c->nth_b);
                c->nth_kind = name[4] == 'l' ? (name[9] == 'c' ? 2 : 4) : (name[4] == 'c' ? 1 : 3);
            } else if (!strcmp(name, "not")) {
                int f, n;
                if (!arg || !css_sel_list(arg, arge, &f, &n)) { c->pseudo |= PS_NEVER; continue; }
                c->nots = f;                              /* (how many: css_ci[f - 1]) */
            } else if (!strcmp(name, "is") || !strcmp(name, "matches") || !strcmp(name, "where") || !strcmp(name, "any")) {
                int f, n;
                if (!arg || !css_sel_list(arg, arge, &f, &n)) { c->pseudo |= PS_NEVER; continue; }
                c->iss = f;
                if (name[0] == 'w') *spec -= 1 << 10;
            } else if (!strcmp(name, "has")) c->pseudo |= PS_NEVER;
            else if (!strcmp(name, "lang") || !strcmp(name, "dir") || !strcmp(name, "defined") ||
                     !strcmp(name, "scope")) ;          /* (taken as yes) */
            else c->pseudo |= PS_NEVER;                   /* hover, focus, visited, target... */
        } else return 0;
    }
    return s;
}
/* "a b > c" (s..e) -> a selector; its index or -1 */
static int css_complex(const char *s, const char *e)
{
    struct ccomp part[16];                               /* (its compounds, put together at the end: */
    int n = 0, first, k;                                 /*  :not()'s own go in before them) */
    unsigned spec = 0;
    unsigned char comb = 0;
    while (s < e) {
        const char *ce;
        int depth = 0;
        while (s < e && (*s == ' ' || *s == '\n' || *s == '\t')) s++;
        if (s >= e) break;
        if (*s == '>' || *s == '+' || *s == '~') {
            comb = *s++;
            continue;
        }
        ce = s;                                           /* the compound: to a space or combinator not in () [] */
        while (ce < e) {
            if (*ce == '(' || *ce == '[') depth++;
            else if (*ce == ')' || *ce == ']') depth--;
            else if (!depth && (*ce == ' ' || *ce == '>' || *ce == '+' || *ce == '~' || *ce == '\n' || *ce == '\t')) break;
            ce++;
        }
        if (n == 16) return -1;
        if (!css_compound(s, ce, &part[n], &spec)) return -1;
        part[n].comb = n ? (comb ? comb : ' ') : 0;
        n++;
        comb = 0;
        s = ce;
    }
    if (!n) return -1;
    if (!CSS_GROW(css_cc, css_ncc, css_cc_cap, n)) return -1;
    first = css_ncc;
    for (k = 0; k < n; k++) css_cc[css_ncc++] = part[k];
    if (!CSS_GROW(css_sel, css_nsel, css_sel_cap, 1)) return -1;
    css_sel[css_nsel].first = first;
    css_sel[css_nsel].n = n;
    css_sel[css_nsel].spec = spec;
    return css_nsel++;
}
/* "a, b.c" (inside :not() / :is()) -> selectors listed in css_ci[*first ..] */
static const char *css_sel_list(const char *s, const char *e, int *first, int *n)
{
    int sels[16], k = 0, i;
    while (s < e) {
        const char *q = s;
        int depth = 0, x;
        while (q < e && (depth || *q != ',')) { if (*q == '(') depth++; else if (*q == ')') depth--; q++; }
        x = css_complex(s, q);
        if (x >= 0 && k < 16) sels[k++] = x;
        s = q < e ? q + 1 : e;
    }
    if (!k) return 0;
    if (!CSS_GROW(css_ci, css_nci, css_ci_cap, k + 1)) return 0;
    css_ci[css_nci++] = k;
    *first = css_nci;
    for (i = 0; i < k; i++) css_ci[css_nci++] = sels[i];
    *n = k;
    return s;
}

/* ---- matching ---- */
static int css_elem_prev(int e) { for (e = dn[e].prev; e && dn[e].type != DN_ELEM; e = dn[e].prev) ; return e; }
static int css_elem_next(int e) { for (e = dn[e].next; e && dn[e].type != DN_ELEM; e = dn[e].next) ; return e; }
static int css_elem_parent(int e) { int p = dn[e].parent; return p && dn[p].type == DN_ELEM ? p : 0; }
static int css_match_sel(int s, int e);
static int css_attr_ok(struct cattr *a, int e)
{
    const char *v = dom_attr_a(e, a->name), *w = css_pool + a->val;
    int vl, wl, i;
    if (!v) return 0;
    if (a->op == 'E') return 1;
    vl = strlen(v); wl = strlen(w);
    if (a->icase || a->name == atom_get("type", 4, 1)) {
        static char lv[256], lw[256];
        for (i = 0; i < vl && i < 255; i++) lv[i] = css_lower(v[i]);
        lv[i] = 0; vl = i;
        for (i = 0; i < wl && i < 255; i++) lw[i] = css_lower(w[i]);
        lw[i] = 0; wl = i;
        v = lv; w = lw;
    }
    switch (a->op) {
    case '=': return !strcmp(v, w);
    case '~': {
        const char *p = v;
        if (!wl) return 0;
        while (*p) {
            while (*p == ' ') p++;
            if (!memcmp(p, w, wl) && (!p[wl] || p[wl] == ' ')) return 1;
            while (*p && *p != ' ') p++;
        }
        return 0;
    }
    case '|': return !strcmp(v, w) || (vl > wl && !memcmp(v, w, wl) && v[wl] == '-');
    case '^': return wl && vl >= wl && !memcmp(v, w, wl);
    case '$': return wl && vl >= wl && !memcmp(v + vl - wl, w, wl);
    case '*': {
        if (!wl) return 0;
        for (i = 0; i + wl <= vl; i++) if (!memcmp(v + i, w, wl)) return 1;
        return 0;
    }
    }
    return 0;
}
static int css_nth_ok(int a, int b, int pos)
{
    if (!a) return pos == b;
    return (pos - b) % a == 0 && (pos - b) / a >= 0;
}
static int css_match_comp(struct ccomp *c, int e)
{
    int i;
    if (dn[e].type != DN_ELEM) return 0;
    if (c->tag && dn[e].tag != c->tag) return 0;
    if (c->pseudo & PS_NEVER) return 0;
    if (c->id) {
        const char *id = dom_attr_a(e, T_NONE + atom_get("id", 2, 1));
        if (!id || strcmp(id, css_pool + c->id)) return 0;
    }
    for (i = 0; i < c->ncls; i++) if (!dom_has_class(e, css_pool + css_ci[c->cls + i])) return 0;
    for (i = 0; i < c->nattr; i++) if (!css_attr_ok(&css_ca[c->attr + i], e)) return 0;
    if (c->pseudo) {
        if ((c->pseudo & (PS_FIRST | PS_ONLY)) && css_elem_prev(e)) return 0;
        if ((c->pseudo & (PS_LAST | PS_ONLY)) && css_elem_next(e)) return 0;
        if (c->pseudo & (PS_FIRST_T | PS_LAST_T | PS_ONLY_T)) {
            int s;
            if (c->pseudo & (PS_FIRST_T | PS_ONLY_T)) for (s = css_elem_prev(e); s; s = css_elem_prev(s)) if (dn[s].tag == dn[e].tag) return 0;
            if (c->pseudo & (PS_LAST_T | PS_ONLY_T)) for (s = css_elem_next(e); s; s = css_elem_next(s)) if (dn[s].tag == dn[e].tag) return 0;
        }
        if ((c->pseudo & PS_ROOT) && e != dom_html) return 0;
        if (c->pseudo & PS_EMPTY) {
            int k;
            for (k = dn[e].first; k; k = dn[k].next) if (dn[k].type == DN_ELEM || (dn[k].type == DN_TEXT && dn[k].tlen)) return 0;
        }
        if ((c->pseudo & PS_LINK) && !((dn[e].tag == T_a || dn[e].tag == T_area) && dom_attr(e, "href"))) return 0;
        if ((c->pseudo & PS_CHECKED) && !dom_attr(e, "checked") && !dom_attr(e, "selected")) return 0;
        if ((c->pseudo & PS_DISABLED) && !dom_attr(e, "disabled")) return 0;
        if ((c->pseudo & PS_ENABLED) && dom_attr(e, "disabled")) return 0;
    }
    if (c->nth_kind) {
        int pos = 1, s;
        if (c->nth_kind == 1) for (s = css_elem_prev(e); s; s = css_elem_prev(s)) pos++;
        else if (c->nth_kind == 2) for (s = css_elem_next(e); s; s = css_elem_next(s)) pos++;
        else if (c->nth_kind == 3) { for (s = css_elem_prev(e); s; s = css_elem_prev(s)) if (dn[s].tag == dn[e].tag) pos++; }
        else for (s = css_elem_next(e); s; s = css_elem_next(s)) if (dn[s].tag == dn[e].tag) pos++;
        if (!css_nth_ok(c->nth_a, c->nth_b, pos)) return 0;
    }
    if (c->nots >= 0) {
        int k, n = css_ci[c->nots - 1];
        for (k = 0; k < n; k++) if (css_match_sel(css_ci[c->nots + k], e)) return 0;
    }
    if (c->iss >= 0) {
        int k, n = css_ci[c->iss - 1], ok = 0;
        for (k = 0; k < n && !ok; k++) if (css_match_sel(css_ci[c->iss + k], e)) ok = 1;
        if (!ok) return 0;
    }
    return 1;
}
static int css_match_from(struct csel *s, int k, int e, int budget)
{
    struct ccomp *c = &css_cc[s->first + k];
    int p;
    if (!css_match_comp(c, e)) return 0;
    if (k == 0) return 1;
    switch (c->comb) {
    case '>': p = css_elem_parent(e); return p && css_match_from(s, k - 1, p, budget);
    case '+': p = css_elem_prev(e); return p && css_match_from(s, k - 1, p, budget);
    case '~': for (p = css_elem_prev(e); p; p = css_elem_prev(p)) if (css_match_from(s, k - 1, p, budget)) return 1; return 0;
    default:
        for (p = css_elem_parent(e); p; p = css_elem_parent(p)) {
            if (css_match_from(s, k - 1, p, budget)) return 1;
            if (--budget <= 0) return 0;
        }
        return 0;
    }
}
static int css_match_sel(int s, int e) { return css_match_from(&css_sel[s], css_sel[s].n - 1, e, 4000); }

/* ---- reading rules ---- */
static int css_prop_id(const char *n);
static void css_add_rule(const char *sel, int decl, int ndecl)
{
    const char *p = sel, *e = sel + strlen(sel);
    while (p < e) {
        const char *q = p;
        int depth = 0, s;
        while (q < e && (depth || *q != ',')) { if (*q == '(' || *q == '[') depth++; else if (*q == ')' || *q == ']') depth--; q++; }
        while (p < q && (*p == ' ' || *p == '\n')) p++;
        if (p < q && (s = css_complex(p, q)) >= 0 && CSS_GROW(css_rules, css_nrules, css_rules_cap, 1)) {
            struct crule *r = &css_rules[css_nrules];
            struct ccomp *c = &css_cc[css_sel[s].first + css_sel[s].n - 1];
            unsigned h;
            r->sel = s; r->decl = decl; r->ndecl = ndecl;
            r->order = css_order++ + css_sheet * 65536;
            r->spec = css_sel[s].spec;
            r->origin = css_origin;
            if (c->id) { h = css_hashs(css_pool + c->id, strlen(css_pool + c->id), 1); r->next = css_bucket[h]; css_bucket[h] = css_nrules; }
            else if (c->ncls) { const char *cn = css_pool + css_ci[c->cls]; h = css_hashs(cn, strlen(cn), 2); r->next = css_bucket[h]; css_bucket[h] = css_nrules; }
            else if (c->tag && c->tag < 512) { r->next = css_tag_bucket[c->tag]; css_tag_bucket[c->tag] = css_nrules; }
            else { r->next = css_any_bucket; css_any_bucket = css_nrules; }
            css_nrules++;
        }
        p = q + 1;
    }
}
/* "a: b; c: d !important" -> declarations; how many */
static int css_decls(const char *d, int *first)
{
    int n = 0;
    *first = css_ndcl;
    while (*d) {
        char name[64], val[1024];
        int k = 0, v = 0, imp = 0, depth = 0, prop;
        char q = 0;
        while (*d == ' ' || *d == ';' || *d == '\n' || *d == '\t') d++;
        if (!*d) break;
        while (*d && *d != ':' && *d != ';') { if (k < 63 && *d != ' ') name[k++] = *d; d++; }
        name[k] = 0;
        if (*d != ':') { while (*d && *d != ';') d++; continue; }
        d++;
        while (*d == ' ') d++;
        while (*d && (q || depth || *d != ';')) {
            if (q) { if (*d == q) q = 0; }
            else if (*d == '"' || *d == '\'') q = *d;
            else if (*d == '(') depth++;
            else if (*d == ')') depth--;
            if (v < 1023) val[v++] = *d;
            d++;
        }
        while (v && (val[v - 1] == ' ' || val[v - 1] == '\n')) v--;
        val[v] = 0;
        {                                                 /* !important */
            int i = v - 1;
            while (i > 0 && val[i] != '!') i--;
            if (i > 0 && css_starts(val + i, "!important")) {
                imp = 1;
                val[i] = 0;
                while (i && val[i - 1] == ' ') val[--i] = 0;
            }
        }
        if (name[0] == '-' && name[1] == '-') prop = 1000 + atom_get(name, strlen(name), 1);
        else {
            int i;
            for (i = 0; name[i]; i++) name[i] = css_lower(name[i]);
            prop = css_prop_id(name);
        }
        if (!prop) continue;
        if (css_base[0] && css_url_fix && css_find(val, "url(")) {          /* url(rel) -> url(the full address) */
            static char out[2048];
            const char *p = val;
            int o = 0;
            while (*p && o < (int)sizeof out - 1) {
                if (css_starts(p, "url(")) {
                    char u[1024], full[1024];
                    int k = 0;
                    p += 4;
                    while (*p == ' ' || *p == '"' || *p == '\'') p++;
                    while (*p && *p != ')' && *p != '"' && *p != '\'' && k < 1023) u[k++] = *p++;
                    u[k] = 0;
                    while (*p && *p != ')') p++;
                    if (*p) p++;
                    if (css_starts(u, "data:") || css_starts(u, "http:") || css_starts(u, "https:") || u[0] == '#') memcpy(full, u, k + 1);
                    else css_url_fix(css_base, u, full);
                    k = strlen(full);
                    if (o + k + 6 < (int)sizeof out) { memcpy(out + o, "url(", 4); o += 4; memcpy(out + o, full, k); o += k; out[o++] = ')'; }
                    continue;
                }
                out[o++] = *p++;
            }
            out[o] = 0;
            memcpy(val, out, o + 1 > 1024 ? 1023 : o + 1);
            val[1023] = 0;
        }
        if (!CSS_GROW(css_dcl, css_ndcl, css_dcl_cap, 1)) break;
        css_dcl[css_ndcl].prop = prop;
        css_dcl[css_ndcl].val = css_str(val, strlen(val));
        css_dcl[css_ndcl].imp = imp;
        css_ndcl++;
        n++;
    }
    return n;
}
static void css_rule_done(const char *sel, const char *decls)
{
    int first, n = css_decls(decls, &first);
    if (n) css_add_rule(sel, first, n);
}

/* ---- @media: as a screen CSS_VW x CSS_VH ---- */
static int css_media_ok(const char *m)
{
    for (;;) {                                            /* "a, b": any of them */
        int ok = 1;
        const char *q;
        char one[200];
        int n = 0;
        while (*m && *m != ',') { if (n < 199) one[n++] = css_lower(*m); m++; }
        one[n] = 0;
        q = one;
        if (css_find(one, "print") || css_find(one, "speech") || css_starts(one, "not ") || css_find(one, " not ")) ok = 0;
        while ((q = css_chr(q, '('))) {
            char f[40];
            int k = 0, num = 0, any = 0;
            q++;
            while (*q == ' ') q++;
            while (*q && *q != ':' && *q != ')' && *q != '<' && *q != '>' && k < 39) { if (*q != ' ') f[k++] = *q; q++; }
            f[k] = 0;
            if (*q == '<' || *q == '>') {                 /* (width >= 600px) */
                int ge = *q == '>';
                q++;
                if (*q == '=') q++;
                while (*q == ' ') q++;
                while (*q >= '0' && *q <= '9') { num = num * 10 + *q++ - '0'; any = 1; }
                if (*q == '.') { q++; while (*q >= '0' && *q <= '9') q++; }
                if (css_starts(q, "em") || css_starts(q, "rem")) num *= 16;
                if (!strcmp(f, "width") && any && (ge ? CSS_VW < num : CSS_VW > num)) ok = 0;
                if (!strcmp(f, "height") && any && (ge ? CSS_VH < num : CSS_VH > num)) ok = 0;
                continue;
            }
            if (*q == ':') {
                q++;
                while (*q == ' ') q++;
                while (*q >= '0' && *q <= '9') { num = num * 10 + *q++ - '0'; any = 1; }
                if (*q == '.') { q++; while (*q >= '0' && *q <= '9') q++; }
                if (css_starts(q, "em") || css_starts(q, "rem")) num *= 16;
            }
            if (!strcmp(f, "max-width") || !strcmp(f, "max-device-width")) { if (any && CSS_VW > num) ok = 0; }
            else if (!strcmp(f, "min-width") || !strcmp(f, "min-device-width")) { if (any && CSS_VW < num) ok = 0; }
            else if (!strcmp(f, "max-height")) { if (any && CSS_VH > num) ok = 0; }
            else if (!strcmp(f, "min-height")) { if (any && CSS_VH < num) ok = 0; }
            else if (!strcmp(f, "prefers-color-scheme")) { if (css_starts(q, "dark")) ok = 0; }
            else if (!strcmp(f, "prefers-reduced-motion")) { if (css_starts(q, "reduce")) ok = 0; }
            else if (!strcmp(f, "orientation")) { if (css_starts(q, "portrait")) ok = 0; }
            else if (!strcmp(f, "hover") || !strcmp(f, "any-hover")) { if (css_starts(q, "none")) ok = 0; }
            else if (!strcmp(f, "pointer") || !strcmp(f, "any-pointer")) { if (css_starts(q, "coarse") || css_starts(q, "none")) ok = 0; }
            else if (!strcmp(f, "-webkit-min-device-pixel-ratio") || !strcmp(f, "min-resolution")) { if (any && num > 1) ok = 0; }
        }
        if (ok) return 1;
        if (*m != ',') return 0;
        m++;
    }
}

/* ---- reading: a character at a time ---- */
enum { CB_RULE, CB_OK, CB_SKIP };
static char css_buf[16384];
static char css_selbuf[4096];
static int css_nbuf, css_depth, css_skip, css_cm, css_quote, css_prev;
static unsigned char css_kind[32];

static void css_begin_sheet(int sheet)
{
    css_nbuf = css_depth = css_skip = css_cm = css_quote = css_prev = 0;
    css_sheet = sheet;
}
static void css_begin(void) { css_begin_sheet(css_sheet); }
static void css_feed(int c)
{
    if (css_cm) {                                         /* in a comment */
        if (css_prev == '*' && c == '/') { css_cm = 0; c = 0; }
        css_prev = c;
        return;
    }
    if (css_prev == '/' && c == '*' && !css_quote) {
        css_cm = 1;
        if (css_nbuf) css_nbuf--;                         /* (its "/") */
        css_prev = 0;
        return;
    }
    css_prev = c;
    if (css_quote) {
        if (c == css_quote) css_quote = 0;
        if (css_nbuf < (int)sizeof css_buf - 1) css_buf[css_nbuf++] = c;
        return;
    }
    if (c == '"' || c == '\'') { css_quote = c; if (css_nbuf < (int)sizeof css_buf - 1) css_buf[css_nbuf++] = c; return; }
    if (c == '{') {
        int kind, s = 0, n = css_nbuf;
        css_buf[n] = 0;
        while (css_buf[s] == ' ') s++;
        while (n > s && css_buf[n - 1] == ' ') css_buf[--n] = 0;
        if (css_skip) kind = CB_SKIP;
        else if (css_depth && css_kind[css_depth - 1 < 31 ? css_depth - 1 : 31] == CB_RULE) kind = CB_SKIP;   /* (nested rules) */
        else if (css_buf[s] == '@') {
            if (css_starts(css_buf + s, "@media")) kind = css_media_ok(css_buf + s + 6) ? CB_OK : CB_SKIP;
            else if (css_starts(css_buf + s, "@supports")) kind = css_find(css_buf + s, "not ") ? CB_SKIP : CB_OK;
            else if (css_starts(css_buf + s, "@layer") || css_starts(css_buf + s, "@document") || css_starts(css_buf + s, "@container") ||
                     css_starts(css_buf + s, "@scope")) kind = CB_OK;
            else kind = CB_SKIP;
        } else {
            int k = 0;
            kind = CB_RULE;
            while (css_buf[s] && k < (int)sizeof css_selbuf - 1) css_selbuf[k++] = css_buf[s++];
            css_selbuf[k] = 0;
        }
        if (css_depth < 32) css_kind[css_depth] = kind;
        css_depth++;
        if (kind == CB_SKIP) css_skip++;
        css_nbuf = 0;
        return;
    }
    if (c == '}') {
        int kind;
        if (!css_depth) { css_nbuf = 0; return; }
        css_depth--;
        kind = css_depth < 32 ? css_kind[css_depth] : CB_SKIP;
        if (kind == CB_SKIP) { if (css_skip) css_skip--; }
        else if (kind == CB_RULE && !css_skip) {
            css_buf[css_nbuf] = 0;
            css_rule_done(css_selbuf, css_buf);
        }
        css_nbuf = 0;
        return;
    }
    if (c == ';' && (!css_depth || (css_depth <= 32 && css_kind[css_depth - 1] != CB_RULE))) {
        css_buf[css_nbuf] = 0;                            /* @import url(...); @charset ...; */
        if (!css_skip && css_starts(css_buf, "@import") && css_nimports < 4) {
            const char *u = css_buf + 7;
            int k = 0;
            while (*u == ' ') u++;
            if (css_starts(u, "url(")) u += 4;
            if (*u == '"' || *u == '\'') u++;
            while (*u && *u != '"' && *u != '\'' && *u != ')' && *u != ' ' && k < 1023) css_imports[css_nimports][k++] = *u++;
            css_imports[css_nimports][k] = 0;
            {
                const char *m = u;
                while (*m && *m != ' ') m++;
                if (k && (!*m || css_media_ok(m))) css_nimports++;
            }
        }
        css_nbuf = 0;
        return;
    }
    if (c == '\n' || c == '\r' || c == '\t' || c == '\f') c = ' ';
    if (c == ' ' && (!css_nbuf || css_buf[css_nbuf - 1] == ' ')) return;
    if (css_nbuf < (int)sizeof css_buf - 1) css_buf[css_nbuf++] = c;
}
static void css_end(void) { css_begin(); }
static void css_text(const char *t, int origin)
{
    int save = css_origin;
    css_origin = origin;
    css_begin();
    while (*t) css_feed(*t++);
    css_end();
    css_origin = save;
}

/* the rules, kept (a tab behind), and back: a malloc'd copy, or 0 */
#define CSS_SAVE(arr, n) { int sz = (n) * (int)sizeof *(arr); memcpy(q, &(n), sizeof(int)); q += sizeof(int); memcpy(q, (arr), sz); q += sz; }
#define CSS_LOAD(arr, n, cap) { int sz; memcpy(&(n), q, sizeof(int)); q += sizeof(int); sz = (n) * (int)sizeof *(arr); \
    if ((n) > (cap)) css_grow((void **)&(arr), &(cap), (n), sizeof *(arr)); memcpy((arr), q, sz); q += sz; }
static void *css_save(void)
{
    int need = 64 + css_ncc * sizeof *css_cc + css_nci * sizeof(int) + css_nca * sizeof *css_ca + css_nsel * sizeof *css_sel +
               css_nrules * sizeof *css_rules + css_ndcl * sizeof *css_dcl + css_npool + sizeof css_bucket + sizeof css_tag_bucket + 8;
    char *b = malloc(need), *q;
    if (!b) return 0;
    q = b;
    CSS_SAVE(css_cc, css_ncc) CSS_SAVE(css_ci, css_nci) CSS_SAVE(css_ca, css_nca) CSS_SAVE(css_sel, css_nsel)
    CSS_SAVE(css_rules, css_nrules) CSS_SAVE(css_dcl, css_ndcl) CSS_SAVE(css_pool, css_npool)
    memcpy(q, css_bucket, sizeof css_bucket); q += sizeof css_bucket;
    memcpy(q, css_tag_bucket, sizeof css_tag_bucket); q += sizeof css_tag_bucket;
    memcpy(q, &css_any_bucket, sizeof(int));
    return b;
}
static void css_restore(const void *saved)
{
    const char *q = saved;
    if (!q) { css_reset(); return; }
    CSS_LOAD(css_cc, css_ncc, css_cc_cap) CSS_LOAD(css_ci, css_nci, css_ci_cap) CSS_LOAD(css_ca, css_nca, css_ca_cap)
    CSS_LOAD(css_sel, css_nsel, css_sel_cap) CSS_LOAD(css_rules, css_nrules, css_rules_cap) CSS_LOAD(css_dcl, css_ndcl, css_dcl_cap)
    CSS_LOAD(css_pool, css_npool, css_pool_cap)
    memcpy(css_bucket, q, sizeof css_bucket); q += sizeof css_bucket;
    memcpy(css_tag_bucket, q, sizeof css_tag_bucket); q += sizeof css_tag_bucket;
    memcpy(&css_any_bucket, q, sizeof(int));
}

/* ================================================================
 * values
 * ================================================================ */
enum {
    CP_NONE, CP_DISPLAY, CP_POSITION, CP_FLOAT, CP_CLEAR, CP_VISIBILITY, CP_COLOR, CP_BG, CP_BGCOLOR, CP_BGIMAGE,
    CP_FONT, CP_FSIZE, CP_FWEIGHT, CP_FSTYLE, CP_TALIGN, CP_TDECO, CP_TTRANS, CP_TINDENT, CP_WS, CP_WIDTH, CP_HEIGHT,
    CP_MINW, CP_MAXW, CP_MINH, CP_MAXH, CP_MARGIN, CP_MT, CP_MR, CP_MB, CP_ML, CP_PADDING, CP_PT, CP_PR, CP_PB, CP_PL,
    CP_BORDER, CP_BT, CP_BR, CP_BB, CP_BL, CP_BWIDTH, CP_BCOLOR, CP_BSTYLE, CP_BTW, CP_BRW, CP_BBW, CP_BLW,
    CP_BTC, CP_BRC, CP_BBC, CP_BLC, CP_BOXSZ, CP_OVERFLOW, CP_OPACITY, CP_LSTYLE, CP_LSTYPE, CP_VALIGN, CP_ZINDEX,
    CP_TOP, CP_RIGHT, CP_BOTTOM, CP_LEFT, CP_INSET, CP_FLEX, CP_FDIR, CP_FWRAP, CP_FFLOW, CP_FGROW, CP_FSHRINK,
    CP_FBASIS, CP_ORDER, CP_JUSTIFY, CP_AITEMS, CP_ASELF, CP_ACONTENT, CP_GAP, CP_RGAP, CP_CGAP, CP_GTC, CP_GTR,
    CP_GTA, CP_GCOL, CP_GROW_, CP_GAREA, CP_GCS, CP_GCE, CP_GRS, CP_GRE, CP_CLIP, CP_TRANSFORM, CP_PLACEITEMS,
    CP_PLACECONTENT, CP_BINLINE, CP_BBLOCK, CP_MINLINE, CP_MBLOCK, CP_PINLINE, CP_PBLOCK, CP_INLSIZE, CP_GRIDTPL,
    CP_WSC, CP_FONTFAM, CP_CONTENTVIS, CP_N
};
static const struct { const char *n; short id; } css_props[] = {
    { "display", CP_DISPLAY }, { "position", CP_POSITION }, { "float", CP_FLOAT }, { "clear", CP_CLEAR },
    { "visibility", CP_VISIBILITY }, { "color", CP_COLOR }, { "background", CP_BG }, { "background-color", CP_BGCOLOR },
    { "background-image", CP_BGIMAGE }, { "font", CP_FONT }, { "font-size", CP_FSIZE }, { "font-weight", CP_FWEIGHT },
    { "font-style", CP_FSTYLE }, { "text-align", CP_TALIGN }, { "text-decoration", CP_TDECO },
    { "text-decoration-line", CP_TDECO }, { "text-transform", CP_TTRANS }, { "text-indent", CP_TINDENT },
    { "white-space", CP_WS }, { "white-space-collapse", CP_WSC }, { "width", CP_WIDTH }, { "height", CP_HEIGHT },
    { "min-width", CP_MINW }, { "max-width", CP_MAXW }, { "min-height", CP_MINH }, { "max-height", CP_MAXH },
    { "margin", CP_MARGIN }, { "margin-top", CP_MT }, { "margin-right", CP_MR }, { "margin-bottom", CP_MB },
    { "margin-left", CP_ML }, { "padding", CP_PADDING }, { "padding-top", CP_PT }, { "padding-right", CP_PR },
    { "padding-bottom", CP_PB }, { "padding-left", CP_PL }, { "border", CP_BORDER }, { "border-top", CP_BT },
    { "border-right", CP_BR }, { "border-bottom", CP_BB }, { "border-left", CP_BL }, { "border-width", CP_BWIDTH },
    { "border-color", CP_BCOLOR }, { "border-style", CP_BSTYLE }, { "border-top-width", CP_BTW },
    { "border-right-width", CP_BRW }, { "border-bottom-width", CP_BBW }, { "border-left-width", CP_BLW },
    { "border-top-color", CP_BTC }, { "border-right-color", CP_BRC }, { "border-bottom-color", CP_BBC },
    { "border-left-color", CP_BLC }, { "box-sizing", CP_BOXSZ }, { "overflow", CP_OVERFLOW }, { "overflow-x", CP_OVERFLOW },
    { "overflow-y", CP_OVERFLOW }, { "opacity", CP_OPACITY }, { "list-style", CP_LSTYLE }, { "list-style-type", CP_LSTYPE },
    { "vertical-align", CP_VALIGN }, { "z-index", CP_ZINDEX }, { "top", CP_TOP }, { "right", CP_RIGHT },
    { "bottom", CP_BOTTOM }, { "left", CP_LEFT }, { "inset", CP_INSET }, { "flex", CP_FLEX },
    { "flex-direction", CP_FDIR }, { "flex-wrap", CP_FWRAP }, { "flex-flow", CP_FFLOW }, { "flex-grow", CP_FGROW },
    { "flex-shrink", CP_FSHRINK }, { "flex-basis", CP_FBASIS }, { "order", CP_ORDER }, { "justify-content", CP_JUSTIFY },
    { "align-items", CP_AITEMS }, { "align-self", CP_ASELF }, { "align-content", CP_ACONTENT }, { "gap", CP_GAP },
    { "grid-gap", CP_GAP }, { "row-gap", CP_RGAP }, { "grid-row-gap", CP_RGAP }, { "column-gap", CP_CGAP },
    { "grid-column-gap", CP_CGAP }, { "grid-template-columns", CP_GTC }, { "grid-template-rows", CP_GTR },
    { "grid-template-areas", CP_GTA }, { "grid-template", CP_GRIDTPL }, { "grid-column", CP_GCOL }, { "grid-row", CP_GROW_ },
    { "grid-area", CP_GAREA }, { "grid-column-start", CP_GCS }, { "grid-column-end", CP_GCE }, { "grid-row-start", CP_GRS },
    { "grid-row-end", CP_GRE }, { "clip", CP_CLIP }, { "clip-path", CP_CLIP }, { "transform", CP_TRANSFORM },
    { "place-items", CP_PLACEITEMS }, { "place-content", CP_PLACECONTENT }, { "margin-inline", CP_MINLINE },
    { "margin-block", CP_MBLOCK }, { "padding-inline", CP_PINLINE }, { "padding-block", CP_PBLOCK },
    { "margin-inline-start", CP_ML }, { "margin-inline-end", CP_MR }, { "margin-block-start", CP_MT },
    { "margin-block-end", CP_MB }, { "padding-inline-start", CP_PL }, { "padding-inline-end", CP_PR },
    { "padding-block-start", CP_PT }, { "padding-block-end", CP_PB }, { "inline-size", CP_WIDTH }, { "block-size", CP_HEIGHT },
    { "max-inline-size", CP_MAXW }, { "min-inline-size", CP_MINW }, { "border-inline", CP_BINLINE }, { "border-block", CP_BBLOCK },
    { "font-family", CP_FONTFAM }, { "content-visibility", CP_CONTENTVIS }, { "inset-inline-start", CP_LEFT },
    { "inset-inline-end", CP_RIGHT }, { "inset-block-start", CP_TOP }, { "inset-block-end", CP_BOTTOM }, { 0, 0 } };
static int css_prop_id(const char *n)
{
    int i;
    if (n[0] == '-') {                                     /* -webkit-box-flex... */
        if (!memcmp(n, "-webkit-", 8)) n += 8; else if (!memcmp(n, "-ms-", 4)) n += 4; else if (!memcmp(n, "-moz-", 5)) n += 5; else return 0;
    }
    for (i = 0; css_props[i].n; i++) if (!strcmp(css_props[i].n, n)) return css_props[i].id;
    return 0;
}

/* ---- colors ---- */
static int css_hex(int c)
{
    c = css_lower(c);
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}
static float css_atof(const char **ps)
{
    const char *s = *ps;
    float r = 0, f = 0.1f, sign = 1;
    int any = 0;
    if (*s == '-') { sign = -1; s++; } else if (*s == '+') s++;
    while (*s >= '0' && *s <= '9') { r = r * 10 + *s++ - '0'; any = 1; }
    if (*s == '.' && s[1] >= '0' && s[1] <= '9') { s++; while (*s >= '0' && *s <= '9') { r += (*s++ - '0') * f; f *= 0.1f; any = 1; } }
    if (any && (*s == 'e' || *s == 'E') && (s[1] == '-' || (s[1] >= '0' && s[1] <= '9'))) {
        int e = 0, es = 1;
        s++;
        if (*s == '-') { es = -1; s++; }
        while (*s >= '0' && *s <= '9') e = e * 10 + *s++ - '0';
        while (e-- > 0) r = es > 0 ? r * 10 : r / 10;
    }
    if (!any) return -99999;
    *ps = s;
    return r * sign;
}
/* s -> *c (0xRRGGBB), *a (0-255); 0 if it isn't a color */
static int css_color(const char *s, unsigned *c, int *a)
{
    static const struct { const char *n; unsigned c; } named[] = {
        { "black", 0 }, { "white", 0xFFFFFF }, { "red", 0xFF0000 }, { "green", 0x008000 }, { "blue", 0x0000FF },
        { "gray", 0x808080 }, { "grey", 0x808080 }, { "yellow", 0xFFFF00 }, { "orange", 0xFFA500 }, { "purple", 0x800080 },
        { "navy", 0x000080 }, { "maroon", 0x800000 }, { "teal", 0x008080 }, { "silver", 0xC0C0C0 }, { "lime", 0x00FF00 },
        { "aqua", 0x00FFFF }, { "cyan", 0x00FFFF }, { "fuchsia", 0xFF00FF }, { "magenta", 0xFF00FF }, { "olive", 0x808000 },
        { "lightblue", 0xADD8E6 }, { "darkblue", 0x00008B }, { "darkred", 0x8B0000 }, { "darkgreen", 0x006400 },
        { "brown", 0xA52A2A }, { "pink", 0xFFC0CB }, { "gold", 0xFFD700 }, { "whitesmoke", 0xF5F5F5 },
        { "lightgray", 0xD3D3D3 }, { "lightgrey", 0xD3D3D3 }, { "darkgray", 0xA9A9A9 }, { "darkgrey", 0xA9A9A9 },
        { "dimgray", 0x696969 }, { "dimgrey", 0x696969 }, { "gainsboro", 0xDCDCDC }, { "beige", 0xF5F5DC }, { "ivory", 0xFFFFF0 },
        { "crimson", 0xDC143C }, { "firebrick", 0xB22222 }, { "steelblue", 0x4682B4 }, { "royalblue", 0x4169E1 },
        { "slategray", 0x708090 }, { "slategrey", 0x708090 }, { "indigo", 0x4B0082 }, { "tomato", 0xFF6347 },
        { "coral", 0xFF7F50 }, { "salmon", 0xFA8072 }, { "skyblue", 0x87CEEB }, { "dodgerblue", 0x1E90FF },
        { "orangered", 0xFF4500 }, { "darkorange", 0xFF8C00 }, { "khaki", 0xF0E68C }, { "lavender", 0xE6E6FA },
        { "linen", 0xFAF0E6 }, { "mintcream", 0xF5FFFA }, { "aliceblue", 0xF0F8FF }, { "ghostwhite", 0xF8F8FF },
        { "honeydew", 0xF0FFF0 }, { "seashell", 0xFFF5EE }, { "snow", 0xFFFAFA }, { "floralwhite", 0xFFFAF0 },
        { "lightyellow", 0xFFFFE0 }, { "lightgreen", 0x90EE90 }, { "forestgreen", 0x228B22 }, { "seagreen", 0x2E8B57 },
        { "darkslategray", 0x2F4F4F }, { "darkslategrey", 0x2F4F4F }, { "midnightblue", 0x191970 }, { "cornflowerblue", 0x6495ED },
        { "deepskyblue", 0x00BFFF }, { "lightskyblue", 0x87CEFA }, { "powderblue", 0xB0E0E6 }, { "cadetblue", 0x5F9EA0 },
        { "darkcyan", 0x008B8B }, { "turquoise", 0x40E0D0 }, { "violet", 0xEE82EE }, { "orchid", 0xDA70D6 },
        { "plum", 0xDDA0DD }, { "hotpink", 0xFF69B4 }, { "deeppink", 0xFF1493 }, { "chocolate", 0xD2691E },
        { "sienna", 0xA0522D }, { "tan", 0xD2B48C }, { "wheat", 0xF5DEB3 }, { "goldenrod", 0xDAA520 },
        { "darkkhaki", 0xBDB76B }, { "olivedrab", 0x6B8E23 }, { "yellowgreen", 0x9ACD32 }, { "limegreen", 0x32CD32 },
        { "springgreen", 0x00FF7F }, { "mediumseagreen", 0x3CB371 }, { "lightcoral", 0xF08080 }, { "indianred", 0xCD5C5C },
        { "mistyrose", 0xFFE4E1 }, { "lightpink", 0xFFB6C1 }, { "palegreen", 0x98FB98 }, { "lightcyan", 0xE0FFFF },
        { "lightsteelblue", 0xB0C4DE }, { "lightslategray", 0x778899 }, { "rebeccapurple", 0x663399 }, { "blueviolet", 0x8A2BE2 },
        { "mediumpurple", 0x9370DB }, { "darkviolet", 0x9400D3 }, { "darkmagenta", 0x8B008B }, { "navajowhite", 0xFFDEAD },
        { "papayawhip", 0xFFEFD5 }, { "antiquewhite", 0xFAEBD7 }, { "oldlace", 0xFDF5E6 }, { "cornsilk", 0xFFF8DC },
        { "lemonchiffon", 0xFFFACD }, { "peachpuff", 0xFFDAB9 }, { "bisque", 0xFFE4C4 }, { "moccasin", 0xFFE4B5 },
        { "burlywood", 0xDEB887 }, { "rosybrown", 0xBC8F8F }, { "sandybrown", 0xF4A460 }, { "peru", 0xCD853F },
        { "saddlebrown", 0x8B4513 }, { "darkgoldenrod", 0xB8860B }, { "darkolivegreen", 0x556B2F }, { "teal", 0x008080 },
        { "transparent", 0 }, { 0, 0 } };
    int i;
    unsigned v = 0;
    while (*s == ' ') s++;
    *a = 255;
    if (*s == '#') {
        int n = 0;
        s++;
        while (css_hex(s[n]) >= 0 && n < 8) n++;
        if (n == 3 || n == 4) {
            *c = css_hex(s[0]) * 0x110000 | css_hex(s[1]) * 0x1100 | css_hex(s[2]) * 0x11;
            if (n == 4) *a = css_hex(s[3]) * 17;
            return 1;
        }
        if (n == 6 || n == 8) {
            for (i = 0; i < 6; i++) v = v << 4 | css_hex(s[i]);
            *c = v;
            if (n == 8) *a = css_hex(s[6]) * 16 + css_hex(s[7]);
            return 1;
        }
        return 0;
    }
    if (css_starts(s, "rgb") || css_starts(s, "hsl")) {   /* rgb(1, 2, 3) rgba() rgb(1 2 3 / .5) hsl() */
        float k[4] = { 0, 0, 0, 1 };
        int j = 0, hsl = css_starts(s, "hsl"), pct[4] = { 0, 0, 0, 0 };
        while (*s && *s != '(') s++;
        if (!*s) return 0;
        s++;
        while (j < 4) {
            float f;
            while (*s == ' ' || *s == ',' || *s == '/') s++;
            if (*s == ')' || !*s) break;
            f = css_atof(&s);
            if (f == -99999) return 0;
            if (*s == '%') { pct[j] = 1; s++; }
            else if (css_starts(s, "deg")) s += 3;
            k[j++] = f;
        }
        if (j < 3) return 0;
        if (j == 4 && pct[3]) k[3] /= 100;
        if (hsl) {                                        /* hsl -> rgb */
            float h = k[0] / 360, sat = k[1] / 100, l = k[2] / 100, q, p, t[3];
            int m;
            h -= (int)h;
            if (h < 0) h += 1;
            q = l < 0.5f ? l * (1 + sat) : l + sat - l * sat;
            p = 2 * l - q;
            t[0] = h + 1.0f / 3; t[1] = h; t[2] = h - 1.0f / 3;
            for (m = 0; m < 3; m++) {
                float x = t[m], r;
                if (x < 0) x += 1;
                if (x > 1) x -= 1;
                r = x < 1.0f / 6 ? p + (q - p) * 6 * x : x < 0.5f ? q : x < 2.0f / 3 ? p + (q - p) * (2.0f / 3 - x) * 6 : p;
                k[m] = r * 255;
            }
        } else for (i = 0; i < 3; i++) if (pct[i]) k[i] = k[i] * 255 / 100;
        for (i = 0; i < 3; i++) k[i] = k[i] < 0 ? 0 : k[i] > 255 ? 255 : k[i];
        *c = (unsigned)(k[0] + 0.5f) << 16 | (unsigned)(k[1] + 0.5f) << 8 | (unsigned)(k[2] + 0.5f);
        *a = (int)(k[3] * 255 + 0.5f);
        if (*a < 0) *a = 0;
        if (*a > 255) *a = 255;
        return 1;
    }
    for (i = 0; named[i].n; i++) {
        int l = strlen(named[i].n);
        if (css_starts(s, named[i].n) && !((s[l] >= 'a' && s[l] <= 'z') || s[l] == '-')) {
            *c = named[i].c;
            if (!strcmp(named[i].n, "transparent")) *a = 0;
            return 1;
        }
    }
    return 0;
}
static unsigned css_mix(unsigned c, int a, unsigned under)
{
    unsigned r, g, b;
    if (a >= 255) return c;
    r = (((c >> 16) & 255) * a + ((under >> 16) & 255) * (255 - a)) / 255;
    g = (((c >> 8) & 255) * a + ((under >> 8) & 255) * (255 - a)) / 255;
    b = ((c & 255) * a + (under & 255) * (255 - a)) / 255;
    return r << 16 | g << 8 | b;
}

/* ---- lengths: px + % (calc() keeps both), em by the font's size ---- */
struct cv { float px, pct, num; unsigned char is_num, ok; };
static float css_fs_cur = 16;                             /* (em: the element's font size) */
static struct cv css_calc(const char **ps, int depth);
static struct cv css_term_val(const char **ps, int depth)
{
    const char *s = *ps;
    struct cv v = { 0, 0, 0, 0, 0 };
    while (*s == ' ') s++;
    if (*s == '(') {
        s++;
        v = css_calc(&s, depth + 1);
        while (*s == ' ') s++;
        if (*s == ')') s++;
        *ps = s;
        return v;
    }
    if (css_starts(s, "calc(") || css_starts(s, "-webkit-calc(")) {
        while (*s != '(') s++;
        s++;
        v = css_calc(&s, depth + 1);
        while (*s == ' ') s++;
        if (*s == ')') s++;
        *ps = s;
        return v;
    }
    if (css_starts(s, "min(") || css_starts(s, "max(") || css_starts(s, "clamp(")) {
        int mx = css_starts(s, "max("), cl = css_starts(s, "clamp(");
        struct cv a[3];
        int n = 0;
        while (*s != '(') s++;
        s++;
        while (n < 3) {
            a[n++] = css_calc(&s, depth + 1);
            while (*s == ' ') s++;
            if (*s == ',') { s++; continue; }
            break;
        }
        while (*s && *s != ')') s++;
        if (*s) s++;
        *ps = s;
        if (cl && n == 3) {                              /* clamp(lo, v, hi): v, kept in [lo, hi] if comparable */
            v = a[1];
            if (!v.pct && !a[0].pct && v.px < a[0].px) v = a[0];
            if (!v.pct && !a[2].pct && v.px > a[2].px) v = a[2];
            if (v.pct && !a[2].pct && a[2].px) v = a[2].px < 400 ? a[2] : v;
            return v;
        }
        v = a[0];
        {
            int i;
            for (i = 1; i < n; i++) {
                if (!a[i].ok) continue;
                if (!v.pct && !a[i].pct) { if (mx ? a[i].px > v.px : a[i].px < v.px) v = a[i]; }
                else if (v.pct && !a[i].pct) { if (!mx) v = a[i]; }       /* (min(100%, 600px): 600px) */
            }
        }
        return v;
    }
    {
        float f = css_atof(&s);
        if (f == -99999) { *ps = s; return v; }
        v.ok = 1;
        if (*s == '%') { v.pct = f; s++; }
        else if (css_starts(s, "px")) { v.px = f; s += 2; }
        else if (css_starts(s, "rem")) { v.px = f * 16; s += 3; }
        else if (css_starts(s, "em")) { v.px = f * css_fs_cur; s += 2; }
        else if (css_starts(s, "vw")) { v.px = f * CSS_VW / 100; s += 2; }
        else if (css_starts(s, "vh")) { v.px = f * CSS_VH / 100; s += 2; }
        else if (css_starts(s, "vmin")) { v.px = f * CSS_VH / 100; s += 4; }
        else if (css_starts(s, "vmax")) { v.px = f * CSS_VW / 100; s += 4; }
        else if (css_starts(s, "dvh") || css_starts(s, "svh") || css_starts(s, "lvh")) { v.px = f * CSS_VH / 100; s += 3; }
        else if (css_starts(s, "dvw") || css_starts(s, "svw") || css_starts(s, "lvw")) { v.px = f * CSS_VW / 100; s += 3; }
        else if (css_starts(s, "pt")) { v.px = f * 4 / 3; s += 2; }
        else if (css_starts(s, "pc")) { v.px = f * 16; s += 2; }
        else if (css_starts(s, "ch")) { v.px = f * 8; s += 2; }
        else if (css_starts(s, "ex")) { v.px = f * 8; s += 2; }
        else if (css_starts(s, "cm")) { v.px = f * 37.8f; s += 2; }
        else if (css_starts(s, "mm")) { v.px = f * 3.78f; s += 2; }
        else if (css_starts(s, "in")) { v.px = f * 96; s += 2; }
        else if (css_starts(s, "fr")) { v.px = f; s += 2; }
        else { v.num = f; v.is_num = 1; v.px = f; }
        while ((*s >= 'a' && *s <= 'z') || *s == '%') s++;
    }
    *ps = s;
    return v;
}
static struct cv css_calc(const char **ps, int depth)
{
    const char *s = *ps;
    struct cv v, t;
    if (depth > 8) { v.ok = 0; return v; }
    v = css_term_val(&s, depth);
    for (;;) {                                            /* * and / */
        while (*s == ' ') s++;
        if (*s == '*' || *s == '/') {
            char op = *s++;
            t = css_term_val(&s, depth);
            if (op == '*') {
                if (t.is_num) { v.px *= t.num; v.pct *= t.num; v.num *= t.num; }
                else if (v.is_num) { float k = v.num; v = t; v.px *= k; v.pct *= k; }
            } else if (t.is_num && t.num) { v.px /= t.num; v.pct /= t.num; v.num /= t.num; }
            continue;
        }
        break;
    }
    for (;;) {                                            /* + and - */
        while (*s == ' ') s++;
        if ((*s == '+' || *s == '-') && (s[1] == ' ' || s[1] == '(')) {
            char op = *s++;
            struct cv u;
            u = css_term_val(&s, depth);
            for (;;) {
                while (*s == ' ') s++;
                if (*s == '*' || *s == '/') {
                    char o2 = *s++;
                    t = css_term_val(&s, depth);
                    if (o2 == '*') { if (t.is_num) { u.px *= t.num; u.pct *= t.num; } else if (u.is_num) { float k = u.num; u = t; u.px *= k; u.pct *= k; } }
                    else if (t.is_num && t.num) { u.px /= t.num; u.pct /= t.num; }
                    continue;
                }
                break;
            }
            if (op == '+') { v.px += u.px; v.pct += u.pct; v.num += u.num; }
            else { v.px -= u.px; v.pct -= u.pct; v.num -= u.num; }
            v.is_num = v.is_num && u.is_num;
            continue;
        }
        break;
    }
    *ps = s;
    return v;
}
/* "12px", "50%", "auto", "calc(100% - 2em)" -> l; 0 if it isn't a length */
static int css_len(const char *s, struct clen *l)
{
    struct cv v;
    while (*s == ' ') s++;
    if (css_starts(s, "auto")) { l->kind = L_AUTO; l->px = l->pct = 0; return 1; }
    if (css_starts(s, "none")) { l->kind = L_NONE; l->px = l->pct = 0; return 1; }
    if (css_starts(s, "max-content") || css_starts(s, "min-content") || css_starts(s, "fit-content") ||
        css_starts(s, "-webkit-fill-available") || css_starts(s, "stretch") || css_starts(s, "-moz-available")) {
        l->kind = css_starts(s, "-webkit-fill") || css_starts(s, "stretch") || css_starts(s, "-moz-av") ? L_AUTO : L_CONTENT;
        l->px = l->pct = 0;
        return 1;
    }
    if (css_starts(s, "initial") || css_starts(s, "unset")) { l->kind = L_UNSET; return 1; }
    v = css_calc(&s, 0);
    if (!v.ok) return 0;
    l->kind = L_LEN;
    l->px = v.px;
    l->pct = v.pct;
    return 1;
}
static int css_resolve(const struct clen *l, int ref) { return (int)(l->px + l->pct * ref / 100 + (l->px < 0 ? -0.5f : 0.5f)); }

/* ---- var() ---- */
static const char *css_var_get(struct cvar *v, int name)
{
    for (; v; v = v->next) if (v->name == name) return css_pool + v->val;
    return 0;
}
/* value text with var(--x, fallback) put in -> out */
static int css_subst(const char *s, char *out, int max, struct cvar *vars, int depth)
{
    int k = 0;
    while (*s && k < max - 1) {
        if (css_starts(s, "var(")) {
            const char *p = s + 4, *ne, *fb = 0, *fe;
            int depth2 = 1, name;
            while (*p == ' ') p++;
            ne = p;
            while (*ne && *ne != ',' && *ne != ')' && *ne != ' ') ne++;
            name = atom_get(p, ne - p, 0);
            fe = ne;
            while (*fe && depth2) {
                if (*fe == '(') depth2++;
                else if (*fe == ')') { if (!--depth2) break; }
                else if (*fe == ',' && depth2 == 1 && !fb) fb = fe + 1;
                fe++;
            }
            {
                const char *val = name ? css_var_get(vars, name) : 0;
                char tmp[1024];
                if (val && depth < 8) {
                    int n = css_subst(val, out + k, max - k, vars, depth + 1);
                    k += n;
                } else if (fb) {
                    int n = fe - fb;
                    if (n > 1023) n = 1023;
                    memcpy(tmp, fb, n);
                    tmp[n] = 0;
                    k += css_subst(tmp, out + k, max - k, vars, depth + 1);
                } else return -1;                         /* (no value, no fallback: the declaration is ignored) */
                if (k < 0) return -1;
            }
            s = *fe ? fe + 1 : fe;
            continue;
        }
        out[k++] = *s++;
    }
    out[k] = 0;
    return k;
}

/* ================================================================
 * the cascade
 * ================================================================ */
static struct cstyle *css_arena;
static int css_narena, css_arena_cap;
static struct cstyle **css_arenas;
static int css_narenas;
static struct cvar *css_vpool;
static int css_nvpool, css_vpool_cap;
static void **css_vpools;
static int css_nvpools;
static int css_reader;                                    /* (the reader: the page's own looks left out) */
static unsigned css_page_bg = 0xFFFFFF;

static void css_styles_free(void)
{
    int i;
    for (i = 0; i < css_narenas; i++) free(css_arenas[i]);
    free(css_arenas);
    css_arenas = 0;
    css_narenas = 0;
    css_arena = 0;
    css_narena = css_arena_cap = 0;
    for (i = 0; i < css_nvpools; i++) free(css_vpools[i]);
    free(css_vpools);
    css_vpools = 0;
    css_nvpools = 0;
    css_vpool = 0;
    css_nvpool = css_vpool_cap = 0;
}
static struct cstyle *css_new_style(void)
{
    if (css_narena == css_arena_cap) {
        struct cstyle **na = realloc(css_arenas, (css_narenas + 1) * sizeof *na);
        if (!na) return 0;
        css_arenas = na;
        css_arena = malloc(1024 * sizeof *css_arena);
        if (!css_arena) return 0;
        css_arenas[css_narenas++] = css_arena;
        css_narena = 0;
        css_arena_cap = 1024;
    }
    return &css_arena[css_narena++];
}
static struct cvar *css_new_var(void)
{
    if (css_nvpool == css_vpool_cap) {
        void **na = realloc(css_vpools, (css_nvpools + 1) * sizeof *na);
        if (!na) return 0;
        css_vpools = na;
        css_vpool = malloc(1024 * sizeof *css_vpool);
        if (!css_vpool) return 0;
        css_vpools[css_nvpools++] = css_vpool;
        css_nvpool = 0;
        css_vpool_cap = 1024;
    }
    return &css_vpool[css_nvpool++];
}

static int css_kw(const char *v, const char *const *names)
{
    int i;
    for (i = 0; names[i]; i++) {
        int l = strlen(names[i]);
        if (css_starts(v, names[i]) && !css_isname((unsigned char)v[l])) return i;
    }
    return -1;
}
static int css_jkw(const char *v)
{
    static const char *const j[] = { "flex-start", "flex-end", "center", "space-between", "space-around", "space-evenly",
        "stretch", "baseline", "auto", "start", "end", "left", "right", "normal", "self-start", "self-end", "first baseline",
        "last baseline", "safe center", "unsafe center", 0 };
    static const unsigned char map[] = { J_START, J_END, J_CENTER, J_BETWEEN, J_AROUND, J_EVENLY, J_STRETCH, J_BASELINE,
        J_AUTO, J_START, J_END, J_START, J_END, J_STRETCH, J_START, J_END, J_BASELINE, J_BASELINE, J_CENTER, J_CENTER };
    int k = css_kw(v, j);
    return k < 0 ? -1 : map[k];
}
static void css_box4(const char *v, struct clen *out)    /* 1-4 lengths: top right bottom left */
{
    struct clen l[4];
    int n = 0;
    while (*v && n < 4) {
        const char *s;
        int depth = 0;
        while (*v == ' ') v++;
        if (!*v) break;
        s = v;
        while (*v && (depth || *v != ' ')) { if (*v == '(') depth++; else if (*v == ')') depth--; v++; }
        {
            char t[256];
            int k = v - s < 255 ? v - s : 255;
            memcpy(t, s, k);
            t[k] = 0;
            if (!css_len(t, &l[n])) return;
            n++;
        }
    }
    if (!n) return;
    out[0] = l[0];
    out[1] = n > 1 ? l[1] : l[0];
    out[2] = n > 2 ? l[2] : l[0];
    out[3] = n > 3 ? l[3] : n > 1 ? l[1] : l[0];
}
static int css_bwidth(const char *v)
{
    struct clen l;
    if (css_starts(v, "thin")) return 1;
    if (css_starts(v, "medium")) return 3;
    if (css_starts(v, "thick")) return 5;
    if (css_len(v, &l) && l.kind == L_LEN) { int w = (int)(l.px + 0.5f); return w > 0 && w < 1 ? 1 : w; }
    return -1;
}
/* "1px solid #ccc" -> width, color, or style none */
static void css_border(struct cstyle *st, int side, const char *v)
{
    int sides[4], ns = 0, i;
    int w = -2, has_c = 0, a = 255;
    unsigned c = st->color;
    const char *p = v;
    if (side < 0) { sides[0] = 0; sides[1] = 1; sides[2] = 2; sides[3] = 3; ns = 4; }
    else if (side == 10) { sides[0] = 1; sides[1] = 3; ns = 2; }
    else if (side == 11) { sides[0] = 0; sides[1] = 2; ns = 2; }
    else { sides[0] = side; ns = 1; }
    if (css_starts(v, "none") || css_starts(v, "0") || css_starts(v, "hidden")) { for (i = 0; i < ns; i++) st->bw[sides[i]] = 0; return; }
    while (*p) {
        char t[128];
        int k = 0, depth = 0;
        while (*p == ' ') p++;
        while (*p && (depth || *p != ' ') && k < 127) { if (*p == '(') depth++; else if (*p == ')') depth--; t[k++] = *p++; }
        t[k] = 0;
        if (!k) break;
        if (css_starts(t, "none") || css_starts(t, "hidden")) w = 0;
        else if (css_kw(t, (const char *const[]){ "solid", "dashed", "dotted", "double", "groove", "ridge", "inset", "outset", 0 }) >= 0) { if (w == -2) w = 3; }
        else if (css_color(t, &c, &a)) has_c = 1;
        else { int bw = css_bwidth(t); if (bw >= 0) w = bw; }
    }
    if (w == -2) w = 0;                                   /* (no style said: none) */
    for (i = 0; i < ns; i++) {
        st->bw[sides[i]] = w > 8 ? 8 : w;
        if (has_c) st->bc[sides[i]] = a < 40 ? 0xFFFFFFFFu : css_mix(c, a, st->eff_bg);
        else st->bc[sides[i]] = st->color;
    }
}
static short css_gline(const char *v, int *area)
{
    struct cv n;
    while (*v == ' ') v++;
    if (css_starts(v, "span")) {
        const char *p = v + 4;
        float f;
        while (*p == ' ') p++;
        f = css_atof(&p);
        return 1000 + (f == -99999 ? 1 : (int)f);
    }
    if (css_starts(v, "auto")) return 0;
    n = css_term_val(&v, 0);
    if (n.ok) return (short)n.num;
    if (area) *area = 1;
    return 0;
}

/* one declaration into st */
static void css_apply(struct cstyle *st, struct cstyle *par, int prop, const char *v)
{
    unsigned c;
    int a, k;
    struct clen l;
    if (css_starts(v, "inherit")) {
        if (!par) return;
        switch (prop) {
        case CP_COLOR: st->color = par->color; return;
        case CP_BGCOLOR: case CP_BG: st->bg = par->bg; st->has_bg = par->has_bg; return;
        case CP_DISPLAY: st->display = par->display; return;
        case CP_WIDTH: st->w = par->w; return;
        case CP_HEIGHT: st->h = par->h; return;
        case CP_FSIZE: st->fsize = par->fsize; return;
        case CP_TALIGN: st->talign = par->talign; return;
        case CP_FWEIGHT: st->bold = par->bold; return;
        case CP_POSITION: st->position = par->position; return;
        case CP_VISIBILITY: st->hidden = par->hidden; return;
        }
        return;
    }
    if (css_starts(v, "initial") || css_starts(v, "unset") || css_starts(v, "revert")) {
        switch (prop) {
        case CP_DISPLAY: case CP_POSITION: case CP_FLOAT: case CP_WIDTH: case CP_HEIGHT: case CP_MAXW: case CP_MINW:
        case CP_MARGIN: case CP_PADDING: case CP_BORDER: case CP_BG: case CP_BGCOLOR: break;
        default: return;
        }
        if (prop == CP_DISPLAY && !css_starts(v, "unset")) { st->display = D_INLINE; return; }
        if (prop == CP_POSITION) { st->position = P_STATIC; return; }
        if (prop == CP_FLOAT) { st->flt = F_NONE; return; }
        if (prop == CP_WIDTH) { st->w.kind = L_AUTO; return; }
        if (prop == CP_HEIGHT) { st->h.kind = L_AUTO; return; }
        if (prop == CP_MAXW) { st->maxw.kind = L_NONE; return; }
        if (prop == CP_BG || prop == CP_BGCOLOR) { st->has_bg = 0; return; }
        return;
    }
    switch (prop) {
    case CP_DISPLAY: {
        static const char *const d[] = { "inline", "block", "none", "inline-block", "flex", "inline-flex", "grid", "inline-grid",
            "list-item", "table", "inline-table", "table-row", "table-cell", "table-row-group", "table-caption", "contents",
            "table-column", "table-header-group", "table-footer-group", "flow-root", "-webkit-box", "-ms-flexbox",
            "-webkit-flex", "box", "-webkit-inline-box", "table-column-group", "ruby", "run-in", 0 };
        static const unsigned char map[] = { D_INLINE, D_BLOCK, D_NONE, D_INLINE_BLOCK, D_FLEX, D_INLINE_FLEX, D_GRID,
            D_INLINE_GRID, D_LIST_ITEM, D_TABLE, D_INLINE_TABLE, D_ROW, D_CELL, D_ROW_GROUP, D_CAPTION, D_CONTENTS, D_COLUMN,
            D_ROW_GROUP, D_ROW_GROUP, D_BLOCK, D_FLEX, D_FLEX, D_FLEX, D_FLEX, D_INLINE_FLEX, D_COLUMN, D_INLINE, D_BLOCK };
        if (css_starts(v, "block flex")) { st->display = D_FLEX; return; }
        if (css_starts(v, "inline flex")) { st->display = D_INLINE_FLEX; return; }
        if (css_starts(v, "block grid")) { st->display = D_GRID; return; }
        if (css_starts(v, "inline grid")) { st->display = D_INLINE_GRID; return; }
        if (css_starts(v, "block flow-root") || css_starts(v, "block flow")) { st->display = D_BLOCK; return; }
        if (css_starts(v, "inline flow-root")) { st->display = D_INLINE_BLOCK; return; }
        k = css_kw(v, d);
        if (k >= 0) st->display = map[k];
        return;
    }
    case CP_POSITION: k = css_kw(v, (const char *const[]){ "static", "relative", "absolute", "fixed", "sticky", "-webkit-sticky", 0 });
        if (k >= 0) st->position = k == 5 ? P_STICKY : k;
        return;
    case CP_FLOAT: k = css_kw(v, (const char *const[]){ "none", "left", "right", "inline-start", "inline-end", 0 });
        if (k >= 0) st->flt = k == 3 ? F_LEFT : k == 4 ? F_RIGHT : k;
        return;
    case CP_CLEAR: k = css_kw(v, (const char *const[]){ "none", "left", "right", "both", "inline-start", "inline-end", 0 });
        if (k >= 0) st->clear = k > 3 ? k - 3 : k;
        return;
    case CP_VISIBILITY: st->hidden = css_starts(v, "hidden") || css_starts(v, "collapse"); return;
    case CP_CONTENTVIS: if (css_starts(v, "hidden")) st->display = D_NONE; return;
    case CP_COLOR:
        if (css_starts(v, "currentcolor")) return;
        if (css_color(v, &c, &a) && a > 30) { st->color = css_mix(c, a, st->eff_bg); st->has_color = 1; }
        return;
    case CP_BGCOLOR: case CP_BG: {
        const char *t = v;
        int got = 0;
        if (prop == CP_BG && (css_starts(v, "none") || css_starts(v, "transparent"))) { st->has_bg = 0; st->bg_url = 0; if (css_starts(v, "none")) return; }
        while (*t) {                                      /* a color among the rest; url() */
            if (css_starts(t, "url(")) {
                const char *u = t + 4, *ue;
                while (*u == ' ' || *u == '"' || *u == '\'') u++;
                ue = u;
                while (*ue && *ue != ')' && *ue != '"' && *ue != '\'') ue++;
                if (ue > u && prop == CP_BG) st->bg_url = css_str(u, ue - u);
                while (*t && *t != ')') t++;
                continue;
            }
            if (css_starts(t, "linear-gradient") || css_starts(t, "radial-gradient") || css_starts(t, "-webkit-linear-gradient") ||
                css_starts(t, "repeating-")) {         /* a gradient: its first color, mixed with its next */
                const char *g = t;
                unsigned c1 = 0, c2 = 0;
                int a1 = 0, a2 = 0, n = 0;
                while (*g && *g != '(') g++;
                while (*g && n < 2) {
                    g++;
                    while (*g == ' ') g++;
                    if (css_color(g, n ? &c2 : &c1, n ? &a2 : &a1)) n++;
                    while (*g && *g != ',' && *g != ')') { if (*g == '(') { while (*g && *g != ')') g++; } if (*g) g++; }
                    if (*g == ')') break;
                }
                if (n) {
                    unsigned m = n == 2 ? css_mix(c1, 128, c2) : c1;
                    int am = n == 2 ? (a1 + a2) / 2 : a1;
                    if (am > 40) { st->bg = css_mix(m, am, st->eff_bg); st->has_bg = 1; got = 1; }
                }
                {
                    int depth = 0;
                    while (*t) { if (*t == '(') depth++; else if (*t == ')') { if (!--depth) { t++; break; } } t++; }
                }
                continue;
            }
            if ((t == v || t[-1] == ' ' || t[-1] == ',') && css_color(t, &c, &a)) {
                if (a > 40) { st->bg = css_mix(c, a, st->eff_bg); st->has_bg = 1; }
                else st->has_bg = 0;
                got = 1;
                break;
            }
            t++;
        }
        if (prop == CP_BGCOLOR && !got && css_starts(v, "transparent")) st->has_bg = 0;
        return;
    }
    case CP_BGIMAGE:
        if (css_starts(v, "url(")) {
            const char *u = v + 4, *ue;
            while (*u == ' ' || *u == '"' || *u == '\'') u++;
            ue = u;
            while (*ue && *ue != ')' && *ue != '"' && *ue != '\'') ue++;
            if (ue > u) st->bg_url = css_str(u, ue - u);
        } else if (css_starts(v, "none")) st->bg_url = 0;
        else css_apply(st, par, CP_BG, v);
        return;
    case CP_FSIZE: {
        int base = par ? par->fsize : 16;
        static const char *const kw[] = { "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large", "smaller", "larger", 0 };
        static const short px[] = { 9, 10, 13, 16, 18, 24, 32, 48, 0, 0 };
        k = css_kw(v, kw);
        if (k >= 0) { st->fsize = k == 8 ? base * 5 / 6 : k == 9 ? base * 6 / 5 : px[k]; return; }
        css_fs_cur = base;
        if (css_len(v, &l) && l.kind == L_LEN) st->fsize = (short)(l.px + l.pct * base / 100);
        if (st->fsize < 6) st->fsize = 6;
        return;
    }
    case CP_FWEIGHT:
        if (css_starts(v, "bold") || css_starts(v, "bolder")) st->bold = 1;
        else if (css_starts(v, "normal") || css_starts(v, "lighter")) st->bold = 0;
        else if (v[0] >= '1' && v[0] <= '9') st->bold = atoi(v) >= 600;
        return;
    case CP_FSTYLE: st->ital = css_starts(v, "italic") || css_starts(v, "oblique"); return;
    case CP_FONT: {                                       /* italic bold 14px/1.4 sans: size, weight, style */
        const char *t = v;
        if (css_kw(v, (const char *const[]){ "caption", "icon", "menu", "message-box", "small-caption", "status-bar", 0 }) >= 0) return;
        st->bold = 0; st->ital = 0;
        while (*t) {
            char w[64];
            int n = 0;
            while (*t == ' ') t++;
            while (*t && *t != ' ' && n < 63) w[n++] = *t++;
            w[n] = 0;
            if (!n) break;
            if (!strcmp(w, "bold") || !strcmp(w, "bolder") || ((w[0] >= '6' && w[0] <= '9') && w[1] == '0' && w[2] == '0')) st->bold = 1;
            else if (!strcmp(w, "italic") || !strcmp(w, "oblique")) st->ital = 1;
            else if ((w[0] >= '0' && w[0] <= '9') || w[0] == '.' || css_starts(w, "calc") || css_starts(w, "var")) {
                char *sl = w;
                while (*sl && *sl != '/') sl++;
                *sl = 0;
                if (w[0] >= '1' && w[0] <= '9' && w[1] == '0' && w[2] == '0' && !w[3]) continue;     /* (a weight) */
                css_apply(st, par, CP_FSIZE, w);
                break;
            } else if (css_kw(w, (const char *const[]){ "small", "medium", "large", "x-large", "xx-large", "x-small", 0 }) >= 0) {
                css_apply(st, par, CP_FSIZE, w);
                break;
            }
        }
        return;
    }
    case CP_TALIGN: k = css_kw(v, (const char *const[]){ "left", "center", "right", "justify", "start", "end", "-webkit-center", "-moz-center", "match-parent", 0 });
        if (k >= 0) st->talign = k == 4 ? TA_LEFT : k == 5 ? TA_RIGHT : k == 6 || k == 7 ? TA_CENTER : k == 3 ? TA_LEFT : k == 8 ? st->talign : k;
        return;
    case CP_TDECO:
        st->under = 0; st->strike = 0;
        { const char *t = v; while (*t) { if (css_starts(t, "underline")) st->under = 1; if (css_starts(t, "line-through")) st->strike = 1; t++; } }
        return;
    case CP_TTRANS: k = css_kw(v, (const char *const[]){ "none", "uppercase", "lowercase", "capitalize", 0 }); if (k >= 0) st->ttrans = k; return;
    case CP_TINDENT: if (css_len(v, &l)) st->tindent = l; return;
    case CP_WS: k = css_kw(v, (const char *const[]){ "normal", "pre", "nowrap", "pre-wrap", "pre-line", "break-spaces", 0 });
        if (k >= 0) st->ws = k == 5 ? WS_PRE_WRAP : k;
        return;
    case CP_WSC: if (css_starts(v, "preserve")) st->ws = WS_PRE_WRAP; return;
    case CP_WIDTH: if (css_len(v, &l)) st->w = l; return;
    case CP_HEIGHT: if (css_len(v, &l)) st->h = l; return;
    case CP_MINW: if (css_len(v, &l)) st->minw = l; return;
    case CP_MAXW: if (css_len(v, &l)) st->maxw = l; return;
    case CP_MINH: if (css_len(v, &l)) st->minh = l; return;
    case CP_MAXH: if (css_len(v, &l)) st->maxh = l; return;
    case CP_MARGIN: css_box4(v, st->m); return;
    case CP_PADDING: css_box4(v, st->p); return;
    case CP_MT: case CP_MR: case CP_MB: case CP_ML: if (css_len(v, &l)) st->m[prop - CP_MT] = l; return;
    case CP_PT: case CP_PR: case CP_PB: case CP_PL: if (css_len(v, &l)) st->p[prop - CP_PT] = l; return;
    case CP_MINLINE: { struct clen b[4]; b[1].kind = L_UNSET; css_box4(v, b); if (b[1].kind != L_UNSET) { st->m[3] = b[0]; st->m[1] = b[1]; } return; }
    case CP_MBLOCK: { struct clen b[4]; b[1].kind = L_UNSET; css_box4(v, b); if (b[1].kind != L_UNSET) { st->m[0] = b[0]; st->m[2] = b[1]; } return; }
    case CP_PINLINE: { struct clen b[4]; b[1].kind = L_UNSET; css_box4(v, b); if (b[1].kind != L_UNSET) { st->p[3] = b[0]; st->p[1] = b[1]; } return; }
    case CP_PBLOCK: { struct clen b[4]; b[1].kind = L_UNSET; css_box4(v, b); if (b[1].kind != L_UNSET) { st->p[0] = b[0]; st->p[2] = b[1]; } return; }
    case CP_BORDER: css_border(st, -1, v); return;
    case CP_BINLINE: css_border(st, 10, v); return;
    case CP_BBLOCK: css_border(st, 11, v); return;
    case CP_BT: case CP_BR: case CP_BB: case CP_BL: css_border(st, prop - CP_BT, v); return;
    case CP_BWIDTH: {
        int w[4], n = 0;
        const char *t = v;
        while (*t && n < 4) {
            char x[32];
            int q = 0;
            while (*t == ' ') t++;
            while (*t && *t != ' ' && q < 31) x[q++] = *t++;
            x[q] = 0;
            if (!q) break;
            w[n] = css_bwidth(x);
            if (w[n] < 0) return;
            n++;
        }
        if (!n) return;
        st->bw[0] = w[0]; st->bw[1] = n > 1 ? w[1] : w[0]; st->bw[2] = n > 2 ? w[2] : w[0]; st->bw[3] = n > 3 ? w[3] : n > 1 ? w[1] : w[0];
        return;
    }
    case CP_BTW: case CP_BRW: case CP_BBW: case CP_BLW: { int w = css_bwidth(v); if (w >= 0) st->bw[prop - CP_BTW] = w > 8 ? 8 : w; return; }
    case CP_BCOLOR: if (css_color(v, &c, &a)) { int i; for (i = 0; i < 4; i++) st->bc[i] = a < 40 ? 0xFFFFFFFFu : css_mix(c, a, st->eff_bg); } return;
    case CP_BTC: case CP_BRC: case CP_BBC: case CP_BLC: if (css_color(v, &c, &a)) st->bc[prop - CP_BTC] = a < 40 ? 0xFFFFFFFFu : css_mix(c, a, st->eff_bg); return;
    case CP_BSTYLE: if (css_starts(v, "none") || css_starts(v, "hidden")) { st->bw[0] = st->bw[1] = st->bw[2] = st->bw[3] = 0; } return;
    case CP_BOXSZ: st->boxsz = css_starts(v, "border-box"); return;
    case CP_OVERFLOW: k = css_kw(v, (const char *const[]){ "visible", "hidden", "auto", "scroll", "clip", "overlay", 0 });
        if (k >= 0) st->overflow = k == 0 ? OV_VISIBLE : k == 1 || k == 4 ? OV_HIDDEN : OV_AUTO;
        return;
    case CP_OPACITY: { const char *t = v; float f = css_atof(&t); if (f != -99999) { if (*t == '%') f /= 100; st->opacity = f; } return; }
    case CP_LSTYLE: case CP_LSTYPE: {
        static const char *const kw[] = { "disc", "circle", "square", "decimal", "none", "lower-alpha", "upper-alpha", "lower-roman",
            "upper-roman", "lower-latin", "upper-latin", "decimal-leading-zero", "georgian", "armenian", "lower-greek", "cjk-decimal", 0 };
        static const unsigned char map[] = { LS_DISC, LS_CIRCLE, LS_SQUARE, LS_DECIMAL, LS_NONE, LS_LALPHA, LS_UALPHA, LS_LROMAN,
            LS_UROMAN, LS_LALPHA, LS_UALPHA, LS_DECIMAL, LS_DECIMAL, LS_DECIMAL, LS_LALPHA, LS_DECIMAL };
        const char *t = v;
        while (*t) {
            k = css_kw(t, kw);
            if (k >= 0) { st->lstyle = map[k]; return; }
            while (*t && *t != ' ') t++;
            while (*t == ' ') t++;
        }
        return;
    }
    case CP_VALIGN: k = css_kw(v, (const char *const[]){ "baseline", "top", "middle", "bottom", "text-top", "text-bottom", 0 });
        if (k >= 0) st->valign = k == 4 ? VA_TOP : k == 5 ? VA_BOTTOM : k;
        return;
    case CP_ZINDEX: st->zindex = atoi(v); return;
    case CP_TOP: case CP_RIGHT: case CP_BOTTOM: case CP_LEFT: if (css_len(v, &l)) st->pos[prop - CP_TOP] = l; return;
    case CP_INSET: css_box4(v, st->pos); return;
    case CP_FLEX: {
        const char *t = v;
        float f;
        if (css_starts(v, "none")) { st->grow = 0; st->shrink = 0; st->basis.kind = L_AUTO; return; }
        if (css_starts(v, "auto")) { st->grow = 1; st->shrink = 1; st->basis.kind = L_AUTO; return; }
        f = css_atof(&t);
        if (f == -99999) { if (css_len(v, &l)) { st->grow = 1; st->shrink = 1; st->basis = l; } return; }
        if (*t && *t != ' ') {                            /* "200px": a basis */
            if (css_len(v, &l)) { st->grow = 1; st->shrink = 1; st->basis = l; }
            return;
        }
        st->grow = f;
        st->shrink = 1;
        st->basis.kind = L_LEN; st->basis.px = 0; st->basis.pct = 0;
        while (*t == ' ') t++;
        if (*t) {
            const char *u = t;
            float g = css_atof(&u);
            if (g != -99999 && (!*u || *u == ' ')) { st->shrink = g; t = u; while (*t == ' ') t++; }
            if (*t && css_len(t, &l)) st->basis = l;
        }
        return;
    }
    case CP_FDIR: k = css_kw(v, (const char *const[]){ "row", "row-reverse", "column", "column-reverse", 0 }); if (k >= 0) st->fdir = k; return;
    case CP_FWRAP: st->fwrap = css_starts(v, "wrap"); return;
    case CP_FFLOW: {
        const char *t = v;
        while (*t) {
            k = css_kw(t, (const char *const[]){ "row", "row-reverse", "column", "column-reverse", 0 });
            if (k >= 0) st->fdir = k;
            if (css_starts(t, "wrap")) st->fwrap = 1;
            if (css_starts(t, "nowrap")) st->fwrap = 0;
            while (*t && *t != ' ') t++;
            while (*t == ' ') t++;
        }
        return;
    }
    case CP_FGROW: { const char *t = v; float f = css_atof(&t); if (f != -99999) st->grow = f; return; }
    case CP_FSHRINK: { const char *t = v; float f = css_atof(&t); if (f != -99999) st->shrink = f; return; }
    case CP_FBASIS: if (css_starts(v, "content")) st->basis.kind = L_AUTO; else if (css_len(v, &l)) st->basis = l; return;
    case CP_ORDER: st->order = atoi(v); return;
    case CP_JUSTIFY: k = css_jkw(v); if (k >= 0) st->justify = k == J_STRETCH || k == J_AUTO ? J_START : k; return;
    case CP_AITEMS: k = css_jkw(v); if (k >= 0) st->aitems = k == J_AUTO ? J_STRETCH : k; return;
    case CP_ASELF: k = css_jkw(v); if (k >= 0) st->aself = k; return;
    case CP_ACONTENT: k = css_jkw(v); if (k >= 0) st->acontent = k; return;
    case CP_PLACEITEMS: k = css_jkw(v); if (k >= 0) st->aitems = k == J_AUTO ? J_STRETCH : k; return;
    case CP_PLACECONTENT: k = css_jkw(v); if (k >= 0) { st->acontent = k; st->justify = k == J_STRETCH ? J_START : k; } return;
    case CP_GAP: {
        struct clen b[4];
        b[0].kind = L_UNSET;
        css_box4(v, b);
        if (b[0].kind == L_UNSET) return;
        st->rgap = b[0];
        st->cgap = b[1];
        return;
    }
    case CP_RGAP: if (css_len(v, &l)) st->rgap = l; return;
    case CP_CGAP: if (css_len(v, &l)) st->cgap = l; return;
    case CP_GTC: st->grid_cols = css_starts(v, "none") ? 0 : css_str(v, strlen(v)); return;
    case CP_GTR: st->grid_rows = css_starts(v, "none") ? 0 : css_str(v, strlen(v)); return;
    case CP_GTA: st->grid_areas = css_starts(v, "none") ? 0 : css_str(v, strlen(v)); return;
    case CP_GRIDTPL: {                                     /* "areas" / cols, or rows / cols */
        const char *sl = v;
        while (*sl && *sl != '/') sl++;
        if (*v == '"' || *v == '\'') st->grid_areas = css_str(v, sl - v);
        if (*sl) st->grid_cols = css_str(sl + 1, strlen(sl + 1));
        return;
    }
    case CP_GCOL: case CP_GROW_: {
        const char *sl = v;
        int area = 0;
        short s0, e0 = 0;
        while (*sl && *sl != '/') sl++;
        s0 = css_gline(v, &area);
        if (*sl) e0 = css_gline(sl + 1, 0);
        if (area && prop == CP_GCOL) { st->grid_area = css_str(v, sl - v); return; }
        if (prop == CP_GCOL) { st->gc_s = s0; st->gc_e = e0; } else { st->gr_s = s0; st->gr_e = e0; }
        return;
    }
    case CP_GCS: st->gc_s = css_gline(v, 0); return;
    case CP_GCE: st->gc_e = css_gline(v, 0); return;
    case CP_GRS: st->gr_s = css_gline(v, 0); return;
    case CP_GRE: st->gr_e = css_gline(v, 0); return;
    case CP_GAREA: {
        const char *t = v;
        int area = 0;
        if (css_isname((unsigned char)*t) && !(*t >= '0' && *t <= '9') && !css_starts(t, "span") && !css_starts(t, "auto")) {
            const char *e = t;
            while (*e && *e != ' ' && *e != '/') e++;
            st->grid_area = css_str(t, e - t);
            return;
        }
        {                                                 /* row-start / col-start / row-end / col-end */
            short v4[4] = { 0, 0, 0, 0 };
            int n = 0;
            while (*t && n < 4) {
                v4[n++] = css_gline(t, &area);
                while (*t && *t != '/') t++;
                if (*t == '/') t++;
            }
            st->gr_s = v4[0]; st->gc_s = v4[1]; st->gr_e = v4[2]; st->gc_e = v4[3];
        }
        return;
    }
    case CP_CLIP:
        if (css_starts(v, "rect(0") || css_starts(v, "inset(50%") || css_starts(v, "rect(1px") || css_starts(v, "polygon(0 0, 0 0") ||
            css_starts(v, "inset(100%")) st->sronly |= 2;
        return;
    case CP_TRANSFORM:
        if (css_starts(v, "scale(0)") || css_starts(v, "translatex(-100") || css_starts(v, "translatey(-100") ||
            css_starts(v, "translateX(-100") || css_starts(v, "translateY(-100") || css_starts(v, "translate(-100%, 0)") ||
            css_starts(v, "translate3d(-100%") || css_starts(v, "translate3d(0, -100%") || css_starts(v, "scaley(0)") ||
            css_starts(v, "scaleY(0)")) st->sronly |= 4;
        return;
    case CP_FONTFAM:
        if (css_starts(v, "monospace") || css_starts(v, "\"courier") || css_starts(v, "courier") || css_starts(v, "consolas") ||
            css_starts(v, "menlo") || css_starts(v, "sfmono") || css_starts(v, "ui-monospace")) st->nowrap_text |= 2;
        return;
    }
}

/* ---- the browser's own sheet ---- */
static const char *css_ua =
    "html,body,div,p,ul,ol,dl,dt,dd,h1,h2,h3,h4,h5,h6,form,header,footer,nav,section,article,aside,main,figure,figcaption,"
    "blockquote,pre,address,hr,fieldset,legend,details,summary,center,menu,dir,hgroup,search,listing,xmp,plaintext,dialog,"
    "frameset,frame,noframes,optgroup{display:block}"
    "head,script,style,title,meta,link,template,base,datalist,param,source,track,area,map,noembed,rp,colgroup>col{display:none}"
    "li{display:list-item}table{display:table}tr{display:table-row}td,th{display:table-cell}"
    "thead,tbody,tfoot{display:table-row-group}caption{display:table-caption}col{display:table-column}"
    "img,input,select,textarea,button,svg,video,iframe,canvas,object,embed,audio,meter,progress,keygen{display:inline-block}"
    "[hidden],dialog:not([open]),option{display:none}"
    "body{margin:8px 18px}"
    "p{margin:12px 0}dl{margin:10px 0}"
    "h1{font-size:2em;margin:18px 0 12px;font-weight:bold}h2{font-size:1.5em;margin:16px 0 10px;font-weight:bold}"
    "h3{font-size:1.17em;margin:14px 0 8px;font-weight:bold}h4,h5,h6{margin:12px 0 6px;font-weight:bold}"
    "b,strong,th,dt{font-weight:bold}i,em,cite,var,dfn,address{font-style:italic}u,ins{text-decoration:underline}"
    "s,strike,del{text-decoration:line-through}"
    "a:link{color:#1a50d0;text-decoration:underline}"
    "code,kbd,samp,tt{color:#aa2864;font-family:monospace}pre{white-space:pre;margin:10px 0;background:#f0f2f6;padding:6px 8px;color:#202028}"
    "pre code{color:inherit}"
    "xmp,listing,plaintext{white-space:pre}"
    "blockquote{margin:10px 36px;font-style:italic}figure{margin:10px 36px}"
    "ul,ol,menu,dir{padding-left:28px;margin:10px 0}ol{list-style-type:decimal}ul ul,ol ul,ul ol,ol ol{margin:2px 0}"
    "ul ul{list-style-type:circle}ul ul ul{list-style-type:square}"
    "dd{margin-left:32px}hr{border-top:2px solid #c4c8d2;margin:10px 0}"
    "center{text-align:center}th{text-align:center}td,th{padding:4px 6px;vertical-align:middle}"
    "table{border-spacing:2px}caption{text-align:center}"
    "fieldset{margin:8px 2px;padding:6px 10px;border:1px solid #b0b8c8}legend{padding:0 4px}"
    "summary{display:block}details>:not(summary){display:none}details[open]>:not(summary){display:block}"
    "sup,sub{font-size:13px}small{font-size:13px}big{font-size:20px}mark{background:#ffef7a;color:#000}"
    "noscript{display:none}"
    "ruby>rt{display:none}";

/* the HTML attributes that say how it looks (bgcolor, align, width...) */
static void css_hints(int e, struct cstyle *st)
{
    const char *a;
    unsigned c;
    int ak;
    struct clen l;
    int t = dn[e].tag;
    if ((a = dom_attr(e, "bgcolor")) && css_color(a, &c, &ak)) { st->bg = c; st->has_bg = 1; }
    if (t == T_font && (a = dom_attr(e, "color")) && css_color(a, &c, &ak)) { st->color = c; st->has_color = 1; }
    if (t == T_font && (a = dom_attr(e, "size"))) {
        static const short fs[] = { 10, 13, 16, 18, 24, 32, 48 };
        int n = atoi(a);
        if (*a == '+') n = 3 + atoi(a + 1); else if (*a == '-') n = 3 - atoi(a + 1);
        if (n < 1) n = 1;
        if (n > 7) n = 7;
        st->fsize = fs[n - 1];
    }
    if ((a = dom_attr(e, "align"))) {
        if (t == T_img || t == T_table) {
            if (css_starts(a, "left")) st->flt = F_LEFT;
            else if (css_starts(a, "right")) st->flt = F_RIGHT;
            else if (css_starts(a, "center") && t == T_table) { st->m[1].kind = st->m[3].kind = L_AUTO; }
        } else if (css_starts(a, "center") || css_starts(a, "middle")) st->talign = TA_CENTER;
        else if (css_starts(a, "right")) st->talign = TA_RIGHT;
        else if (css_starts(a, "left")) st->talign = TA_LEFT;
    }
    if ((t == T_td || t == T_th || t == T_tr) && (a = dom_attr(e, "valign")))
        st->valign = css_starts(a, "top") ? VA_TOP : css_starts(a, "bottom") ? VA_BOTTOM : VA_MIDDLE;
    if (t == T_img || t == T_table || t == T_td || t == T_th || t == T_iframe || t == T_video || t == T_canvas ||
        t == T_input || t == T_hr || t == T_object || t == T_embed || t == T_col) {
        if ((a = dom_attr(e, "width")) && css_len(a, &l) && l.kind == L_LEN) st->w = l;
        if (t != T_td && t != T_th && (a = dom_attr(e, "height")) && css_len(a, &l) && l.kind == L_LEN) st->h = l;
    }
    if (t == T_table && (a = dom_attr(e, "border")) && atoi(a) > 0) {
        st->bw[0] = st->bw[1] = st->bw[2] = st->bw[3] = 1;
        st->bc[0] = st->bc[1] = st->bc[2] = st->bc[3] = 0xA0A6B4;
    }
    if (t == T_table && (a = dom_attr(e, "cellpadding"))) { st->sronly |= 0; }
    if (t == T_body) {
        if ((a = dom_attr(e, "text")) && css_color(a, &c, &ak)) { st->color = c; st->has_color = 1; }
        if ((a = dom_attr(e, "marginwidth"))) { st->m[1].px = st->m[3].px = atoi(a); st->m[1].pct = st->m[3].pct = 0; }
    }
    if (t == T_hr && (a = dom_attr(e, "noshade"))) { st->bw[0] = 2; }
    if ((t == T_ul || t == T_ol || t == T_li) && (a = dom_attr(e, "type"))) {
        if (!strcmp(a, "a")) st->lstyle = LS_LALPHA; else if (!strcmp(a, "A")) st->lstyle = LS_UALPHA;
        else if (!strcmp(a, "i")) st->lstyle = LS_LROMAN; else if (!strcmp(a, "I")) st->lstyle = LS_UROMAN;
        else if (!strcmp(a, "1")) st->lstyle = LS_DECIMAL; else if (css_starts(a, "circle")) st->lstyle = LS_CIRCLE;
        else if (css_starts(a, "square")) st->lstyle = LS_SQUARE; else if (css_starts(a, "disc")) st->lstyle = LS_DISC;
    }
    if (t == T_nobr) st->ws = WS_NOWRAP;
    if (t == T_pre && dom_attr(e, "wrap")) st->ws = WS_PRE_WRAP;
}

/* a style's start: what's inherited from par, the rest as CSS begins it */
static void css_initial(struct cstyle *st, struct cstyle *par)
{
    int i;
    memset(st, 0, sizeof *st);
    st->display = D_INLINE;
    st->w.kind = st->h.kind = L_AUTO;
    st->minw.kind = st->minh.kind = L_AUTO;
    st->maxw.kind = st->maxh.kind = L_NONE;
    for (i = 0; i < 4; i++) { st->m[i].kind = L_LEN; st->p[i].kind = L_LEN; st->pos[i].kind = L_AUTO; }
    st->basis.kind = L_AUTO;
    st->rgap.kind = st->cgap.kind = L_UNSET;
    st->shrink = 1;
    st->opacity = 1;
    st->aitems = J_STRETCH;
    st->aself = J_AUTO;
    st->acontent = J_START;
    for (i = 0; i < 4; i++) st->bc[i] = 0;
    if (par) {
        st->color = par->color;
        st->bold = par->bold;
        st->ital = par->ital;
        st->under = par->under;
        st->strike = par->strike;
        st->fsize = par->fsize;
        st->talign = par->talign;
        st->ws = par->ws;
        st->ttrans = par->ttrans;
        st->hidden = par->hidden;
        st->lstyle = par->lstyle;
        st->vars = par->vars;
        st->eff_bg = par->has_bg ? par->bg : par->eff_bg;
        st->nowrap_text = par->nowrap_text & 2;
    } else {
        st->color = 0x202028;
        st->fsize = 16;
        st->eff_bg = css_page_bg;
    }
    for (i = 0; i < 4; i++) st->bc[i] = st->color;
}

/* the rules matching e, in the order they apply */
struct cmatch { int rule; unsigned spec; int order; unsigned char origin; };
static struct cmatch *css_mt;
static int css_mt_cap;
static unsigned *css_seen;
static int css_seen_cap;
static unsigned css_stamp;
static int css_candidates(int e, int n, int b)
{
    for (; b >= 0; b = css_rules[b].next) {
        if (css_seen[b] == css_stamp) continue;
        css_seen[b] = css_stamp;
        if (!css_match_sel(css_rules[b].sel, e)) continue;
        if (!CSS_GROW(css_mt, n, css_mt_cap, 1)) break;
        css_mt[n].rule = b;
        css_mt[n].spec = css_rules[b].spec;
        css_mt[n].order = css_rules[b].order;
        css_mt[n].origin = css_rules[b].origin;
        n++;
    }
    return n;
}
static int css_mt_less(struct cmatch *a, struct cmatch *b)
{
    if (a->origin != b->origin) return a->origin < b->origin;
    if (a->spec != b->spec) return a->spec < b->spec;
    return a->order < b->order;
}
static int css_matches(int e)
{
    int n = 0, i, j;
    const char *id, *cl;
    if (css_seen_cap < css_nrules) {
        unsigned *ns = realloc(css_seen, css_nrules * 2 * sizeof *ns + 4);
        if (!ns) return 0;
        memset(ns, 0, css_nrules * 2 * sizeof *ns + 4);
        css_seen = ns;
        css_seen_cap = css_nrules * 2;
        css_stamp = 0;
    }
    css_stamp++;
    if ((id = dom_attr(e, "id")) && *id) n = css_candidates(e, n, css_bucket[css_hashs(id, strlen(id), 1)]);
    if ((cl = dom_attr(e, "class"))) {
        const char *p = cl;
        while (*p) {
            const char *s;
            while (*p == ' ' || *p == '\t' || *p == '\n') p++;
            s = p;
            while (*p && *p != ' ' && *p != '\t' && *p != '\n') p++;
            if (p > s) n = css_candidates(e, n, css_bucket[css_hashs(s, p - s, 2)]);
        }
    }
    if (dn[e].tag < 512) n = css_candidates(e, n, css_tag_bucket[dn[e].tag]);
    n = css_candidates(e, n, css_any_bucket);
    for (i = 1; i < n; i++) {                            /* in order: origin, specificity, place */
        struct cmatch m = css_mt[i];
        for (j = i; j > 0 && css_mt_less(&m, &css_mt[j - 1]); j--) css_mt[j] = css_mt[j - 1];
        css_mt[j] = m;
    }
    return n;
}

static void css_apply_decl(struct cstyle *st, struct cstyle *par, int prop, const char *v)
{
    static char buf[4096];
    if (prop >= 1000) return;
    if (css_find(v, "var(")) {
        if (css_subst(v, buf, sizeof buf, st->vars, 0) < 0) return;
        v = buf;
    }
    css_fs_cur = st->fsize;
    css_apply(st, par, prop, v);
}
/* inline style="...": its declarations, parsed each time */
static void css_inline_pass(struct cstyle *st, struct cstyle *par, const char *s, int want_imp, int vars_only)
{
    while (*s) {
        char name[64], val[1024];
        int k = 0, v = 0, imp = 0, depth = 0, prop;
        char q = 0;
        while (*s == ' ' || *s == ';' || *s == '\n' || *s == '\t') s++;
        if (!*s) break;
        while (*s && *s != ':' && *s != ';') { if (k < 63 && *s != ' ') name[k++] = css_lower(*s); s++; }
        name[k] = 0;
        if (*s != ':') { while (*s && *s != ';') s++; continue; }
        s++;
        while (*s == ' ') s++;
        while (*s && (q || depth || *s != ';')) {
            if (q) { if (*s == q) q = 0; } else if (*s == '"' || *s == '\'') q = *s;
            else if (*s == '(') depth++; else if (*s == ')') depth--;
            if (v < 1023) val[v++] = *s;
            s++;
        }
        while (v && val[v - 1] == ' ') v--;
        val[v] = 0;
        {
            int i = v - 1;
            while (i > 0 && val[i] != '!') i--;
            if (i > 0 && css_starts(val + i, "!important")) { imp = 1; val[i] = 0; }
        }
        if (imp != want_imp) continue;
        if (name[0] == '-' && name[1] == '-') {
            if (vars_only) {
                struct cvar *cv = css_new_var();
                if (cv) { cv->name = atom_get(name, strlen(name), 1); cv->val = css_str(val, strlen(val)); cv->next = st->vars; st->vars = cv; }
            }
            continue;
        }
        if (vars_only) continue;
        prop = css_prop_id(name);
        if (prop) css_apply_decl(st, par, prop, val);
    }
}

/* e's style, from its parent's */
static void css_style_of(int e, struct cstyle *st, struct cstyle *par)
{
    int n, i, k, pass;
    const char *inl = css_reader ? 0 : dom_attr(e, "style");
    css_initial(st, par);
    n = css_matches(e);
    for (i = 0; i < n; i++) {                            /* custom properties first */
        struct crule *r = &css_rules[css_mt[i].rule];
        for (k = 0; k < r->ndecl; k++) {
            struct cdecl *d = &css_dcl[r->decl + k];
            if (d->prop >= 1000) {
                struct cvar *cv = css_new_var();
                if (!cv) continue;
                cv->name = d->prop - 1000;
                cv->val = d->val;
                cv->next = st->vars;
                st->vars = cv;
            }
        }
    }
    if (inl) css_inline_pass(st, par, inl, 0, 1);
    for (pass = 0; pass < 2; pass++) {                   /* normal, then !important */
        int hinted = pass || css_reader;
        for (i = 0; i < n; i++) {
            struct crule *r = &css_rules[css_mt[i].rule];
            if (!hinted && r->origin) { css_hints(e, st); hinted = 1; }
            if (css_reader && r->origin) {               /* (the reader: only what hides) */
                if (pass) continue;
                for (k = 0; k < r->ndecl; k++) {
                    struct cdecl *d = &css_dcl[r->decl + k];
                    if (d->prop == CP_DISPLAY && css_starts(css_pool + d->val, "none")) st->display = D_NONE;
                    if (d->prop == CP_VISIBILITY && css_starts(css_pool + d->val, "hidden")) st->hidden = 1;
                }
                continue;
            }
            for (k = 0; k < r->ndecl; k++) {
                struct cdecl *d = &css_dcl[r->decl + k];
                if (d->imp == pass) css_apply_decl(st, par, d->prop, css_pool + d->val);
            }
        }
        if (!hinted) css_hints(e, st);
        if (inl) css_inline_pass(st, par, inl, pass, 0);
    }
    if (st->opacity < 0.05f) st->sronly |= 8;
}

/* every element's style, from root down (an element's parent's first) */
static void css_load_ua(void) { css_text(css_ua, 0); }
static int dom_skip(int n, int root)                     /* past n and all in it */
{
    while (n && n != root) { if (dn[n].next) return dn[n].next; n = dn[n].parent; }
    return 0;
}
static void css_compute_tree(int root)
{
    int e = root;
    css_styles_free();
    while (e) {
        struct cstyle *st, *par;
        if (dn[e].type != DN_ELEM) { dn[e].cs = 0; e = dom_next_in(e, root); continue; }
        par = dn[e].parent && dn[dn[e].parent].type == DN_ELEM ? dn[dn[e].parent].cs : 0;
        st = css_new_style();
        if (st) css_style_of(e, st, par);
        dn[e].cs = st;
        if (!st || st->display == D_NONE || (dn[e].flags & DF_TPL)) {        /* (what's inside: not needed) */
            int d;
            for (d = dn[e].first; d; d = dom_next_in(d, e)) dn[d].cs = 0;
            e = dom_skip(e, root);
            continue;
        }
        e = dom_next_in(e, root);
    }
}

#endif
