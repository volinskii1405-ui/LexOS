/* css.h - the little CSS LexOS Web understands: style sheets read a
 * character at a time (from <style>, or a <link>ed file as it comes),
 * kept as rules of simple selectors - a tag, .classes, an #id, or those
 * together ("p.note", "div#main.wide") - and applied to an element:
 *
 *   css_reset();  css_feed(c) ...  css_end();
 *   struct css_style s = { 0 };
 *   css_match("div", "a b", "top", &s);   the rules for it, in order
 *   css_inline("color:red", &s);          its style="..." last
 *
 * What's kept: display:none (and visibility:hidden, and the "only for
 * screen readers" trick - absolute, 1px, clipped) - hidden; color;
 * background(-color); font-weight bold; font-style italic; underline;
 * text-align:center. @media is judged as a screen 800 wide and 600
 * high; other @-blocks are passed over; selectors with more than that
 * (a b, a > b, :hover, [x]) are left out - rather nothing than the
 * wrong thing. */
#ifndef CSS_H
#define CSS_H
#include "lexos.h"

#define CSS_VW 800
#define CSS_VH 600
#define CSS_RULES 2400
#define CSS_POOL (48 * 1024)
#define CSS_BUCKETS 512

enum { CS_HIDE = 1, CS_SHOW = 2, CS_BOLD = 4, CS_NOBOLD = 8, CS_ITAL = 16, CS_UNDER = 32,
       CS_CENTER = 64, CS_COLOR = 128, CS_BG = 256 };

struct css_style { char hide, bold, ital, under, center, has_color, has_bg; unsigned color, bg; };

struct css_rule { short tag, cls1, cls2, id, next; unsigned short set; unsigned color, bg; };
static struct css_rule css_rules[CSS_RULES];
static int css_nrules;
static char css_pool[CSS_POOL];
static int css_npool;
static short css_bucket[CSS_BUCKETS];

/* ---- little helpers ---- */
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
static int css_ncmp(const char *a, const char *b, int n)
{
    while (n-- > 0) { if (*a != *b) return (unsigned char)*a - (unsigned char)*b; if (!*a) return 0; a++; b++; }
    return 0;
}

/* ---- colors ---- */
static int css_lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
static int css_hex(int c)
{
    c = css_lower(c);
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}
static int css_starts(const char *s, const char *p)
{
    while (*p) if (css_lower((unsigned char)*s++) != css_lower((unsigned char)*p++)) return 0;
    return 1;
}
/* s -> *c (0xRRGGBB); 0 if it isn't a color */
static int css_color(const char *s, unsigned *c)
{
    static const struct { const char *n; unsigned c; } named[] = {
        { "black", 0 }, { "white", 0xFFFFFF }, { "red", 0xCC2222 }, { "green", 0x118811 },
        { "blue", 0x2233CC }, { "gray", 0x808080 }, { "grey", 0x808080 }, { "yellow", 0xEEDD22 },
        { "orange", 0xEE8811 }, { "purple", 0x882299 }, { "navy", 0x112266 }, { "maroon", 0x800000 },
        { "teal", 0x118888 }, { "silver", 0xC0C0C0 }, { "lightblue", 0xADD8E6 }, { "darkblue", 0x00008B },
        { "darkred", 0x8B0000 }, { "darkgreen", 0x006400 }, { "brown", 0xA52A2A }, { "pink", 0xFFC0CB },
        { "gold", 0xFFD700 }, { "olive", 0x808000 }, { "lime", 0x00CC00 }, { "aqua", 0x00CCCC },
        { "cyan", 0x00CCCC }, { "fuchsia", 0xCC00CC }, { "magenta", 0xCC00CC }, { "whitesmoke", 0xF5F5F5 },
        { "lightgray", 0xD3D3D3 }, { "lightgrey", 0xD3D3D3 }, { "darkgray", 0xA9A9A9 }, { "darkgrey", 0xA9A9A9 },
        { "dimgray", 0x696969 }, { "gainsboro", 0xDCDCDC }, { "beige", 0xF5F5DC }, { "ivory", 0xFFFFF0 },
        { "crimson", 0xDC143C }, { "firebrick", 0xB22222 }, { "steelblue", 0x4682B4 }, { "royalblue", 0x4169E1 },
        { "slategray", 0x708090 }, { "indigo", 0x4B0082 }, { "tomato", 0xFF6347 }, { 0, 0 } };
    int i;
    unsigned v = 0;
    while (*s == ' ') s++;
    if (*s == '#') {
        int n = 0;
        s++;
        while (css_hex(s[n]) >= 0 && n < 8) n++;
        if (n == 3 || n == 4) {
            *c = css_hex(s[0]) * 0x110000 | css_hex(s[1]) * 0x1100 | css_hex(s[2]) * 0x11;
            return 1;
        }
        if (n == 6 || n == 8) {
            for (i = 0; i < 6; i++) v = v << 4 | css_hex(s[i]);
            *c = v;
            return 1;
        }
        return 0;
    }
    if (css_starts(s, "rgb")) {                              /* rgb(1, 2, 3) / rgba / rgb(1 2 3) */
        int k[3], j = 0;
        while (*s && *s != '(') s++;
        if (!*s) return 0;
        s++;
        while (j < 3) {
            int n = 0, any = 0;
            while (*s == ' ' || *s == ',') s++;
            while (*s >= '0' && *s <= '9') { n = n * 10 + *s++ - '0'; any = 1; }
            if (*s == '.') { s++; while (*s >= '0' && *s <= '9') s++; }
            if (*s == '%') { n = n * 255 / 100; s++; }
            if (!any) return 0;
            k[j++] = n > 255 ? 255 : n;
        }
        *c = k[0] << 16 | k[1] << 8 | k[2];
        return 1;
    }
    for (i = 0; named[i].n; i++) {
        int l = strlen(named[i].n);
        if (css_starts(s, named[i].n) && !((s[l] >= 'a' && s[l] <= 'z') || s[l] == '-')) { *c = named[i].c; return 1; }
    }
    return 0;
}

/* ---- the rules ---- */
static void css_reset(void);
static int css_str(const char *s, int n)
{
    int at = css_npool;
    if (css_npool + n + 1 > CSS_POOL) return -2;
    memcpy(css_pool + css_npool, s, n);
    css_pool[css_npool + n] = 0;
    css_npool += n + 1;
    return at;
}
static unsigned css_hash(const char *s, int n)
{
    unsigned h = 5381;
    while (n--) h = h * 33 + (unsigned char)*s++;
    return h & (CSS_BUCKETS - 1);
}

/* a declaration block's text -> what it sets */
static unsigned css_decls(const char *d, unsigned *color, unsigned *bg)
{
    unsigned set = 0;
    int abs = 0, tiny = 0, zero_h = 0, clipped = 0, padded = 0;
    while (*d) {
        char name[32], val[160];
        int n = 0, v = 0;
        while (*d == ' ' || *d == ';') d++;
        while (*d && *d != ':' && *d != ';') { if (n < 31 && *d != ' ') name[n++] = css_lower(*d); d++; }
        name[n] = 0;
        if (*d != ':') { while (*d && *d != ';') d++; continue; }
        d++;
        while (*d == ' ') d++;
        while (*d && *d != ';') { if (v < 159) val[v++] = css_lower(*d); d++; }
        while (v && val[v - 1] == ' ') v--;
        val[v] = 0;
        {                                                 /* (no !important) */
            char *im = val;
            while (*im && *im != '!') im++;
            *im = 0;
            while (im > val && im[-1] == ' ') *--im = 0;
        }
        if (!strcmp(name, "display")) set = (set & ~(CS_HIDE | CS_SHOW)) | (!strcmp(val, "none") ? CS_HIDE : CS_SHOW);
        else if (!strcmp(name, "visibility")) { if (!strcmp(val, "hidden")) set = (set & ~CS_SHOW) | CS_HIDE; }
        else if (!strcmp(name, "font-weight"))
            set = (set & ~(CS_BOLD | CS_NOBOLD)) | (!strcmp(val, "bold") || !strcmp(val, "bolder") || (val[0] >= '6' && val[0] <= '9' && val[1] == '0') ? CS_BOLD : CS_NOBOLD);
        else if (!strcmp(name, "font-style")) { if (!strcmp(val, "italic") || !strcmp(val, "oblique")) set |= CS_ITAL; }
        else if (!strcmp(name, "text-decoration") || !strcmp(name, "text-decoration-line")) {
            const char *u = val;
            while (*u && !css_starts(u, "underline")) u++;
            if (*u) set |= CS_UNDER;
        }
        else if (!strcmp(name, "text-align")) { if (!strcmp(val, "center")) set |= CS_CENTER; }
        else if (!strcmp(name, "color")) { if (css_color(val, color)) set |= CS_COLOR; }
        else if (!strcmp(name, "background-color") || !strcmp(name, "background")) {
            const char *t = val;                          /* (a color among the rest) */
            while (*t) {
                if (css_starts(t, "url(")) { while (*t && *t != ')') t++; continue; }
                if ((t == val || t[-1] == ' ') && css_color(t, bg)) { set |= CS_BG; break; }
                t++;
            }
        }
        else if (!strcmp(name, "position")) { if (!strcmp(val, "absolute") || !strcmp(val, "fixed")) abs = 1; }
        else if (!strcmp(name, "padding-bottom") || !strcmp(name, "padding-top") || !strcmp(name, "padding")) { if (val[0] > '0' && val[0] <= '9') padded = 1; }
        else if (!strcmp(name, "clip") || !strcmp(name, "clip-path")) tiny = 1;
        else if ((!strcmp(name, "width") || !strcmp(name, "height")) && (!strcmp(val, "1px") || !strcmp(val, "0") || !strcmp(val, "0px"))) {
            tiny = 1;
            if (name[0] == 'h' && val[0] == '0') zero_h = 1;
        }
        else if (!strcmp(name, "left") && val[0] == '-' && strlen(val) > 5) tiny = 1;      /* left:-9999px */
        else if (!strcmp(name, "top") && val[0] == '-' && strlen(val) > 5) tiny = 1;
        else if (!strcmp(name, "opacity") && (!strcmp(val, "0") || !strcmp(val, "0.0"))) tiny = 1;
        else if (!strcmp(name, "transform") && (css_starts(val, "scale(0)") || css_starts(val, "translatex(-100") ||
                                                 css_starts(val, "translatey(-100"))) tiny = 1;
        else if ((!strcmp(name, "height") || !strcmp(name, "max-height")) && (!strcmp(val, "0") || !strcmp(val, "0px"))) zero_h = 1;
        else if (!strcmp(name, "overflow") || !strcmp(name, "overflow-y")) { if (!strcmp(val, "hidden") || !strcmp(val, "clip")) clipped = 1; }
        else if (!strcmp(name, "text-indent") && val[0] == '-' && strlen(val) > 5) set = (set & ~CS_SHOW) | CS_HIDE;   /* text for a picture */
    }
    if (abs && tiny) set = (set & ~CS_SHOW) | CS_HIDE;    /* "for screen readers only" */
    if (zero_h && clipped && !padded) set = (set & ~CS_SHOW) | CS_HIDE;          /* folded away */
    return set;
}

/* a selector ("div.a#b", no more than that) and what it sets -> a rule */
static void css_add(const char *s, int n, unsigned set, unsigned color, unsigned bg)
{
    struct css_rule *r;
    const char *e = s + n, *p = s;
    const char *tag = 0, *c1 = 0, *c2 = 0, *id = 0;
    int ltag = 0, l1 = 0, l2 = 0, lid = 0;
    const char *key;
    int lkey;
    unsigned h;
    if (!n || css_nrules >= CSS_RULES) return;
    for (p = s; p < e; p++)
        if (*p == ' ' || *p == '>' || *p == '+' || *p == '~' || *p == ':' || *p == '[' || *p == '*' || *p == '(') return;
    p = s;
    if ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z')) {
        tag = p;
        while (p < e && *p != '.' && *p != '#') p++;
        ltag = p - tag;
    }
    while (p < e) {
        char k = *p++;
        const char *t = p;
        while (p < e && *p != '.' && *p != '#') p++;
        if (p == t) return;
        if (k == '#') { if (id) return; id = t; lid = p - t; }
        else if (!c1) { c1 = t; l1 = p - t; }
        else if (!c2) { c2 = t; l2 = p - t; }
        else return;
    }
    if (!tag && !c1 && !id) return;
    r = &css_rules[css_nrules];
    r->tag = r->cls1 = r->cls2 = r->id = -1;
    if (tag) {
        char low[32];
        int i;
        if (ltag > 31) return;
        for (i = 0; i < ltag; i++) low[i] = css_lower(tag[i]);
        r->tag = css_str(low, ltag);
    }
    if (c1) r->cls1 = css_str(c1, l1);
    if (c2) r->cls2 = css_str(c2, l2);
    if (id) r->id = css_str(id, lid);
    if (r->tag == -2 || r->cls1 == -2 || r->cls2 == -2 || r->id == -2) return;
    r->set = set;
    r->color = color;
    r->bg = bg;
    if (id) { key = id; lkey = lid; }                     /* its bucket: by the id, */
    else if (c1) { key = c1; lkey = l1; }                 /* its first class, */
    else { key = css_pool + r->tag; lkey = ltag; }        /* or its tag */
    h = css_hash(key, lkey);
    r->next = css_bucket[h];
    css_bucket[h] = css_nrules++;
}

/* "a, b.c { ... }" read: each simple selector a rule */
static void css_rule_done(const char *sel, const char *decls)
{
    unsigned color = 0, bg = 0, set = css_decls(decls, &color, &bg);
    const char *p = sel;
    if (!set) return;
    while (*p) {
        const char *s;
        int n;
        while (*p == ' ' || *p == ',') p++;
        s = p;
        while (*p && *p != ',') p++;
        n = p - s;
        while (n && s[n - 1] == ' ') n--;
        css_add(s, n, set, color, bg);
    }
}

/* ---- @media: as a screen CSS_VW x CSS_VH ---- */
static int css_media_ok(const char *m)
{
    for (;;) {                                            /* "a, b": any of them */
        int ok = 1;
        const char *q = m;
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
            while (*q && *q != ':' && *q != ')' && k < 39) { if (*q != ' ') f[k++] = *q; q++; }
            f[k] = 0;
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
            else if (!strcmp(f, "orientation")) { if (css_starts(q, "portrait")) ok = 0; }
            else if (!strcmp(f, "hover") || !strcmp(f, "any-hover")) { if (css_starts(q, "none")) ok = 0; }
            else if (!strcmp(f, "pointer") || !strcmp(f, "any-pointer")) { if (css_starts(q, "coarse") || css_starts(q, "none")) ok = 0; }
        }
        if (ok) return 1;
        if (*m != ',') return 0;
        m++;
    }
}

/* ---- reading: a character at a time ---- */
enum { CB_RULE, CB_OK, CB_SKIP };
static char css_buf[2048];
static char css_sel[1024];
static int css_nbuf, css_depth, css_skip, css_cm, css_quote, css_prev;
static unsigned char css_kind[24];

static void css_reset(void)
{
    int i;
    css_nrules = css_npool = 0;
    for (i = 0; i < CSS_BUCKETS; i++) css_bucket[i] = -1;
    css_nbuf = css_depth = css_skip = css_cm = css_quote = css_prev = 0;
}
/* a new sheet begins (another <style>, another file) */
static void css_begin(void)
{
    css_nbuf = css_depth = css_skip = css_cm = css_quote = css_prev = 0;
}
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
        else if (css_buf[s] == '@') {
            if (css_starts(css_buf + s, "@media")) kind = css_media_ok(css_buf + s + 6) ? CB_OK : CB_SKIP;
            else if (css_starts(css_buf + s, "@supports") || css_starts(css_buf + s, "@layer") ||
                     css_starts(css_buf + s, "@document") || css_starts(css_buf + s, "@container")) kind = CB_OK;
            else kind = CB_SKIP;
        } else {
            kind = CB_RULE;
            {
                int k = 0;
                while (css_buf[s] && k < (int)sizeof css_sel - 1) css_sel[k++] = css_buf[s++];
                css_sel[k] = 0;
            }
        }
        if (css_depth < (int)sizeof css_kind) css_kind[css_depth] = kind;
        css_depth++;
        if (kind == CB_SKIP) css_skip++;
        css_nbuf = 0;
        return;
    }
    if (c == '}') {
        int kind;
        if (!css_depth) { css_nbuf = 0; return; }
        css_depth--;
        kind = css_depth < (int)sizeof css_kind ? css_kind[css_depth] : CB_SKIP;
        if (kind == CB_SKIP) { if (css_skip) css_skip--; }
        else if (kind == CB_RULE && !css_skip) {
            css_buf[css_nbuf] = 0;
            css_rule_done(css_sel, css_buf);
        }
        css_nbuf = 0;
        return;
    }
    if (c == ';' && (!css_depth || (css_depth <= (int)sizeof css_kind && css_kind[css_depth - 1] != CB_RULE))) {
        css_nbuf = 0;                                     /* @import ...; @charset ...; */
        return;
    }
    if (c == '\n' || c == '\r' || c == '\t' || c == '\f') c = ' ';
    if (c == ' ' && (!css_nbuf || css_buf[css_nbuf - 1] == ' ')) return;
    if (css_nbuf < (int)sizeof css_buf - 1) css_buf[css_nbuf++] = c;
}
static void css_end(void) { css_begin(); }

/* ---- an element: the rules that match it, in the order they came ---- */
static int css_has_class(const char *list, const char *c)
{
    int n = strlen(c);
    while (*list) {
        while (*list == ' ') list++;
        if (!css_ncmp(list, c, n) && (list[n] == ' ' || !list[n])) return 1;
        while (*list && *list != ' ') list++;
    }
    return 0;
}
static void css_apply(struct css_style *st, unsigned set, unsigned color, unsigned bg)
{
    if (set & CS_HIDE) st->hide = 1;
    if (set & CS_SHOW) st->hide = 0;
    if (set & CS_BOLD) st->bold = 1;
    if (set & CS_NOBOLD) st->bold = 0;
    if (set & CS_ITAL) st->ital = 1;
    if (set & CS_UNDER) st->under = 1;
    if (set & CS_CENTER) st->center = 1;
    if (set & CS_COLOR) { st->has_color = 1; st->color = color; }
    if (set & CS_BG) { st->has_bg = 1; st->bg = bg; }
}
static void css_match(const char *tag, const char *cls, const char *id, struct css_style *st)
{
    short hits[96];
    int nh = 0, i, j;
    const char *keys[18];
    int lkeys[18], nk = 0;
    if (!css_nrules) return;
    keys[nk] = tag; lkeys[nk++] = strlen(tag);
    if (id && *id) { keys[nk] = id; lkeys[nk++] = strlen(id); }
    if (cls) {                                            /* each class */
        const char *p = cls;
        while (*p && nk < 18) {
            while (*p == ' ') p++;
            if (!*p) break;
            keys[nk] = p;
            while (*p && *p != ' ') p++;
            lkeys[nk] = p - keys[nk];
            nk++;
        }
    }
    for (i = 0; i < nk; i++) {
        int r = css_bucket[css_hash(keys[i], lkeys[i])];
        for (; r >= 0 && nh < 96; r = css_rules[r].next) {
            struct css_rule *u = &css_rules[r];
            int dup = 0;
            if (u->tag >= 0 && strcmp(css_pool + u->tag, tag)) continue;
            if (u->id >= 0 && (!id || strcmp(css_pool + u->id, id))) continue;
            if (u->cls1 >= 0 && (!cls || !css_has_class(cls, css_pool + u->cls1))) continue;
            if (u->cls2 >= 0 && (!cls || !css_has_class(cls, css_pool + u->cls2))) continue;
            for (j = 0; j < nh; j++) if (hits[j] == r) { dup = 1; break; }
            if (!dup) hits[nh++] = r;
        }
    }
    for (i = 1; i < nh; i++) {                            /* in their order */
        short v = hits[i];
        for (j = i; j > 0 && hits[j - 1] > v; j--) hits[j] = hits[j - 1];
        hits[j] = v;
    }
    for (i = 0; i < nh; i++) css_apply(st, css_rules[hits[i]].set, css_rules[hits[i]].color, css_rules[hits[i]].bg);
}
/* the rules, kept (a tab behind), and back: a malloc'd copy, or 0 */
static void *css_save(void)
{
    int n = sizeof(int) * 2 + css_nrules * sizeof(struct css_rule) + css_npool + sizeof css_bucket;
    char *b = malloc(n), *q;
    if (!b) return 0;
    q = b;
    memcpy(q, &css_nrules, sizeof(int)); q += sizeof(int);
    memcpy(q, &css_npool, sizeof(int)); q += sizeof(int);
    memcpy(q, css_rules, css_nrules * sizeof(struct css_rule)); q += css_nrules * sizeof(struct css_rule);
    memcpy(q, css_pool, css_npool); q += css_npool;
    memcpy(q, css_bucket, sizeof css_bucket);
    return b;
}
static void css_restore(const void *saved)
{
    const char *q = saved;
    if (!q) { css_reset(); return; }
    memcpy(&css_nrules, q, sizeof(int)); q += sizeof(int);
    memcpy(&css_npool, q, sizeof(int)); q += sizeof(int);
    memcpy(css_rules, q, css_nrules * sizeof(struct css_rule)); q += css_nrules * sizeof(struct css_rule);
    memcpy(css_pool, q, css_npool); q += css_npool;
    memcpy(css_bucket, q, sizeof css_bucket);
}

/* style="..." */
static void css_inline(const char *decls, struct css_style *st)
{
    unsigned color = 0, bg = 0, set = css_decls(decls, &color, &bg);
    css_apply(st, set, color, bg);
}

#endif
