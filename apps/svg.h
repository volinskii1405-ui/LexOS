/* svg.h - SVG pictures drawn into pixels: <img src="x.svg">, and <svg>
 * written into a page (logos, icons).
 *
 *   unsigned *svg_render(text, n, want_w, want_h, bg, color, &w, &h)
 *
 * -> 0xRRGGBB pixels (malloc'd) over bg, want_w x want_h (0: the
 * picture's own size - width/height, or its viewBox - keeping its
 * proportions); color is what "currentColor" means. 0 if it isn't SVG.
 *
 * What it draws: <path> (all of its commands, arcs too), <rect> (with
 * rounded corners), <circle>, <ellipse>, <line>, <polyline>,
 * <polygon>, <g>, <svg> inside <svg>, <use> of what has an id (and
 * <symbol>s); fill and stroke (a color, none, currentColor, a gradient
 * - as its middle color), stroke-width, opacity, fill-opacity,
 * stroke-opacity, fill-rule, transform="..." (matrix, translate,
 * scale, rotate, skewX, skewY), viewBox, style="..." and a <style>'s
 * .class / #id / tag rules. Edges are smoothed (5 rows a pixel, the
 * columns by how much is covered). Not drawn: <text>, <image>, masks,
 * clipping, filters, patterns, dashes. */
#ifndef SVG_H
#define SVG_H
#include "lexos.h"

/* ---- numbers ---- */
static int svg_isspace(int c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ','; }
static int svg_lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
static const char *svg_num(const char *s, float *v)
{
    float r = 0, sign = 1, frac = 0.1f;
    int any = 0, e = 0, es = 1;
    while (svg_isspace(*s)) s++;
    if (*s == '-') { sign = -1; s++; } else if (*s == '+') s++;
    while (*s >= '0' && *s <= '9') { r = r * 10 + (*s++ - '0'); any = 1; }
    if (*s == '.') {
        s++;
        while (*s >= '0' && *s <= '9') { r += (*s++ - '0') * frac; frac *= 0.1f; any = 1; }
    }
    if (!any) return 0;
    if ((*s == 'e' || *s == 'E') && (s[1] == '-' || s[1] == '+' || (s[1] >= '0' && s[1] <= '9'))) {
        s++;
        if (*s == '-') { es = -1; s++; } else if (*s == '+') s++;
        while (*s >= '0' && *s <= '9') e = e * 10 + (*s++ - '0');
        while (e-- > 0) r = es > 0 ? r * 10 : r / 10;
    }
    *v = r * sign;
    return s;
}
/* a length: "12", "12px", "1.5em", "50%" (of ref) */
static float svg_len(const char *s, float ref, float dflt)
{
    float v;
    const char *e;
    if (!s || !(e = svg_num(s, &v))) return dflt;
    if (*e == '%') return v * ref / 100;
    if (e[0] == 'e' && e[1] == 'm') return v * 16;
    if (e[0] == 'p' && e[1] == 't') return v * 4 / 3;
    if (e[0] == 'r' && e[1] == 'e' && e[2] == 'm') return v * 16;
    return v;
}

/* ---- math (no libm needed) ---- */
static float svg_sqrt(float x)
{
    float r = x > 1 ? x : 1;
    int i;
    if (x <= 0) return 0;
    for (i = 0; i < 20; i++) r = 0.5f * (r + x / r);
    return r;
}
#define SVG_PI 3.14159265f
static float svg_sin(float x)
{
    float x2, r;
    while (x > SVG_PI) x -= 2 * SVG_PI;
    while (x < -SVG_PI) x += 2 * SVG_PI;
    if (x > SVG_PI / 2) x = SVG_PI - x;
    else if (x < -SVG_PI / 2) x = -SVG_PI - x;
    x2 = x * x;
    r = x * (1 - x2 / 6 * (1 - x2 / 20 * (1 - x2 / 42 * (1 - x2 / 72))));
    return r;
}
static float svg_cos(float x) { return svg_sin(x + SVG_PI / 2); }
static float svg_atan2(float y, float x)
{
    float a, ax = x < 0 ? -x : x, ay = y < 0 ? -y : y, t, t2;
    if (ax < 1e-9f && ay < 1e-9f) return 0;
    t = ax > ay ? ay / ax : ax / ay;
    t2 = t * t;
    a = t * (0.99997726f + t2 * (-0.33262347f + t2 * (0.19354346f + t2 * (-0.11643287f + t2 * (0.05265332f - t2 * 0.01172120f)))));
    if (ay > ax) a = SVG_PI / 2 - a;
    if (x < 0) a = SVG_PI - a;
    if (y < 0) a = -a;
    return a;
}

/* ---- colors ---- */
static int svg_hex(int c)
{
    c = svg_lower(c);
    return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
}
/* -> 1 and *c (0xRRGGBB), *a (0..255) if it's a color; 2 if "none" */
static int svg_color(const char *s, unsigned cur, unsigned *c, int *a)
{
    static const struct { const char *n; unsigned c; } named[] = {
        { "black", 0 }, { "white", 0xFFFFFF }, { "red", 0xFF0000 }, { "green", 0x008000 }, { "blue", 0x0000FF },
        { "gray", 0x808080 }, { "grey", 0x808080 }, { "yellow", 0xFFFF00 }, { "orange", 0xFFA500 },
        { "purple", 0x800080 }, { "navy", 0x000080 }, { "maroon", 0x800000 }, { "teal", 0x008080 },
        { "silver", 0xC0C0C0 }, { "lime", 0x00FF00 }, { "aqua", 0x00FFFF }, { "cyan", 0x00FFFF },
        { "fuchsia", 0xFF00FF }, { "magenta", 0xFF00FF }, { "olive", 0x808000 }, { "gold", 0xFFD700 },
        { "pink", 0xFFC0CB }, { "brown", 0xA52A2A }, { "darkgray", 0xA9A9A9 }, { "darkgrey", 0xA9A9A9 },
        { "lightgray", 0xD3D3D3 }, { "lightgrey", 0xD3D3D3 }, { "dimgray", 0x696969 }, { "whitesmoke", 0xF5F5F5 },
        { "crimson", 0xDC143C }, { "tomato", 0xFF6347 }, { "steelblue", 0x4682B4 }, { "royalblue", 0x4169E1 },
        { "dodgerblue", 0x1E90FF }, { "darkblue", 0x00008B }, { "darkred", 0x8B0000 }, { "darkgreen", 0x006400 },
        { "indigo", 0x4B0082 }, { "coral", 0xFF7F50 }, { "salmon", 0xFA8072 }, { "skyblue", 0x87CEEB },
        { "lightblue", 0xADD8E6 }, { "orangered", 0xFF4500 }, { "slategray", 0x708090 }, { "transparent", 0 }, { 0, 0 } };
    int i, n = 0;
    while (*s == ' ') s++;
    *a = 255;
    if (!*s) return 0;
    if (!memcmp(s, "none", 4)) return 2;
    if (!memcmp(s, "currentColor", 12) || !memcmp(s, "currentcolor", 12) || !memcmp(s, "inherit", 7)) { *c = cur; return 1; }
    if (*s == '#') {
        unsigned v = 0;
        s++;
        while (svg_hex(s[n]) >= 0 && n < 8) n++;
        if (n == 3 || n == 4) {
            *c = svg_hex(s[0]) * 0x110000 | svg_hex(s[1]) * 0x1100 | svg_hex(s[2]) * 0x11;
            if (n == 4) *a = svg_hex(s[3]) * 17;
            return 1;
        }
        if (n == 6 || n == 8) {
            for (i = 0; i < 6; i++) v = v << 4 | svg_hex(s[i]);
            *c = v;
            if (n == 8) *a = svg_hex(s[6]) * 16 + svg_hex(s[7]);
            return 1;
        }
        return 0;
    }
    if (!memcmp(s, "rgb", 3)) {
        float k[4] = { 0, 0, 0, 1 };
        const char *t = s;
        while (*t && *t != '(') t++;
        if (!*t) return 0;
        t++;
        for (i = 0; i < 4; i++) {
            const char *e;
            while (*t == ' ' || *t == ',' || *t == '/') t++;
            if (!(e = svg_num(t, &k[i]))) break;
            if (*e == '%') { k[i] = i < 3 ? k[i] * 255 / 100 : k[i] / 100; e++; }
            t = e;
        }
        if (i < 3) return 0;
        for (i = 0; i < 3; i++) k[i] = k[i] < 0 ? 0 : k[i] > 255 ? 255 : k[i];
        *c = (unsigned)k[0] << 16 | (unsigned)k[1] << 8 | (unsigned)k[2];
        *a = (int)(k[3] * 255);
        if (*a < 0) *a = 0;
        if (*a > 255) *a = 255;
        return 1;
    }
    for (i = 0; named[i].n; i++) {
        int l = strlen(named[i].n), j;
        for (j = 0; j < l && svg_lower(s[j]) == named[i].n[j]; j++) ;
        if (j == l && !((s[l] >= 'a' && s[l] <= 'z') || (s[l] >= 'A' && s[l] <= 'Z'))) {
            *c = named[i].c;
            if (!strcmp(named[i].n, "transparent")) *a = 0;
            return 1;
        }
    }
    return 0;
}

/* ---- the document: a tree of elements, read from the text ---- */
#define SVG_ATTRS 24
struct svg_el {
    char name[16];
    int parent, first, next, nattr;
    const char *an[SVG_ATTRS], *av[SVG_ATTRS];           /* (in the copy: 0-ended) */
};
struct svg_doc {
    struct svg_el *el;
    int n, cap;
    char *text;                                          /* the copy, cut up */
    char *style;                                         /* the <style>s, joined */
    int nstyle;
};

static int svg_new(struct svg_doc *d, int parent, const char *name)
{
    struct svg_el *e;
    int i;
    if (d->n == d->cap) {
        int nc = d->cap ? d->cap * 2 : 64;
        struct svg_el *ne;
        if (nc > 20000) return -1;
        ne = realloc(d->el, nc * sizeof *ne);
        if (!ne) return -1;
        d->el = ne;
        d->cap = nc;
    }
    e = &d->el[d->n];
    memset(e, 0, sizeof *e);
    for (i = 0; i < 15 && name[i]; i++) e->name[i] = svg_lower(name[i]);
    e->parent = parent;
    e->first = e->next = -1;
    if (parent >= 0) {                                   /* last among its parent's */
        int c = d->el[parent].first;
        if (c < 0) d->el[parent].first = d->n;
        else { while (d->el[c].next >= 0) c = d->el[c].next; d->el[c].next = d->n; }
    }
    return d->n++;
}

static const char *svg_attr(struct svg_doc *d, int i, const char *name)
{
    int k;
    if (i < 0) return 0;
    for (k = 0; k < d->el[i].nattr; k++) if (!strcmp(d->el[i].an[k], name)) return d->el[i].av[k];
    return 0;
}

/* the text (copied, then cut up in place) -> the tree; 0 if no <svg> */
static int svg_parse(struct svg_doc *d, const char *src, int n)
{
    char *t = malloc(n + 1), *p, *end;
    int cur = -1, root = -1;
    if (!t) return 0;
    memcpy(t, src, n);
    t[n] = 0;
    d->text = t;
    p = t;
    end = t + n;
    while (p < end) {
        char *q, *name;
        int closing = 0, self = 0, e;
        if (*p != '<') { p++; continue; }
        if (p[1] == '!' || p[1] == '?') {                /* comments, <!DOCTYPE>, <?xml?>, CDATA */
            if (!memcmp(p, "<!--", 4)) { q = p + 4; while (q < end && memcmp(q, "-->", 3)) q++; p = q + 3; continue; }
            if (!memcmp(p, "<![CDATA[", 9)) { q = p + 9; while (q < end && memcmp(q, "]]>", 3)) q++; p = q + 3; continue; }
            while (p < end && *p != '>') p++;
            p++;
            continue;
        }
        p++;
        if (*p == '/') { closing = 1; p++; }
        name = p;
        while (p < end && !svg_isspace(*p) && *p != '>' && *p != '/') p++;
        {
            char *colon = name;                          /* (svg:path -> path) */
            while (colon < p && *colon != ':') colon++;
            if (colon < p) name = colon + 1;
        }
        if (closing) {
            char nm[16];
            int k = 0;
            while (name + k < p && k < 15) { nm[k] = svg_lower(name[k]); k++; }
            nm[k] = 0;
            while (p < end && *p != '>') p++;
            p++;
            while (cur >= 0 && strcmp(d->el[cur].name, nm)) cur = d->el[cur].parent;     /* (badly nested) */
            if (cur >= 0) cur = d->el[cur].parent;
            continue;
        }
        {
            char sv = *p;
            *p = 0;
            e = svg_new(d, cur, name);
            *p = sv;
        }
        if (e < 0) break;
        if (root < 0 && !strcmp(d->el[e].name, "svg")) root = e;
        while (p < end && *p != '>') {                   /* its attributes */
            char *an, *av = 0;
            if (svg_isspace(*p)) { *p++ = 0; continue; }
            if (*p == '/') { self = 1; *p++ = 0; continue; }
            an = p;
            while (p < end && !svg_isspace(*p) && *p != '=' && *p != '>' && *p != '/') p++;
            if (*p == '=') {
                *p++ = 0;
                if (*p == '"' || *p == '\'') {
                    char qc = *p++;
                    av = p;
                    while (p < end && *p != qc) p++;
                    if (p < end) *p++ = 0;
                } else {
                    av = p;
                    while (p < end && !svg_isspace(*p) && *p != '>') p++;
                }
            } else if (p < end && *p != '>') *p++ = 0;
            if (d->el[e].nattr < SVG_ATTRS) {
                char *c = an;
                for (; *c && *c != '=' && !svg_isspace(*c) && *c != '>' && *c != '/'; c++) *c = svg_lower(*c);
                if (!memcmp(an, "xlink:href", 10)) an += 6;
                d->el[e].an[d->el[e].nattr] = an;
                d->el[e].av[d->el[e].nattr++] = av ? av : "";
            }
        }
        if (p < end) *p++ = 0;
        {                                                /* (names cut where they ended) */
            char *c = name;
            while (*c && !svg_isspace(*c) && *c != '>' && *c != '/') c++;
            *c = 0;
        }
        if (!strcmp(d->el[e].name, "style") && !self) {  /* its rules, kept */
            char *s = p;
            while (p < end && !(p[0] == '<' && p[1] == '/')) p++;
            {
                int l = p - s, k;
                char *ns = realloc(d->style, d->nstyle + l + 2);
                if (ns) {
                    d->style = ns;
                    for (k = 0; k < l; k++) {
                        char c = s[k];
                        if (!memcmp(s + k, "<![CDATA[", 9)) { k += 8; continue; }
                        if (!memcmp(s + k, "]]>", 3)) { k += 2; continue; }
                        d->style[d->nstyle++] = c;
                    }
                    d->style[d->nstyle++] = ' ';
                    d->style[d->nstyle] = 0;
                }
            }
            cur = e;                                     /* (its </style> closes it) */
            continue;
        }
        if (!self) cur = e;
    }
    return root >= 0;
}

/* a property: from style="...", then the <style>'s rules (by .class,
 * #id, tag - the last match), then the attribute */
static int svg_decl(const char *decls, const char *name, char *out, int max)
{
    int l = strlen(name);
    const char *s = decls;
    int found = 0;
    while (s && *s) {
        const char *nm, *v;
        int k = 0;
        while (*s == ' ' || *s == ';' || *s == '\n' || *s == '\t' || *s == '\r') s++;
        nm = s;
        while (*s && *s != ':' && *s != ';') s++;
        if (*s != ':') { while (*s && *s != ';') s++; continue; }
        {
            const char *ne = s;
            while (ne > nm && (ne[-1] == ' ' || ne[-1] == '\t')) ne--;
            v = s + 1;
            while (*v == ' ') v++;
            s = v;
            while (*s && *s != ';' && *s != '}') s++;
            if (ne - nm == l && !memcmp(nm, name, l)) {
                const char *ve = s;
                while (ve > v && (ve[-1] == ' ' || ve[-1] == '\n' || ve[-1] == '\r' || ve[-1] == '\t')) ve--;
                for (k = 0; v + k < ve && k < max - 1; k++) out[k] = v[k];
                out[k] = 0;
                {                                         /* (no !important) */
                    char *im = out;
                    while (*im && *im != '!') im++;
                    *im = 0;
                }
                found = 1;
            }
        }
        if (*s == '}') break;
    }
    return found;
}
static int svg_sel_match(struct svg_doc *d, int e, const char *sel, int len)
{
    const char *cl;
    while (len && sel[len - 1] == ' ') len--;
    while (len && *sel == ' ') { sel++; len--; }
    {                                                    /* (the last of "a b": what it must be) */
        int k;
        for (k = len - 1; k >= 0; k--) if (sel[k] == ' ' || sel[k] == '>') { sel += k + 1; len -= k + 1; break; }
    }
    if (!len) return 0;
    if (*sel == '.') {
        int cl_len;
        const char *c;
        cl = svg_attr(d, e, "class");
        if (!cl) return 0;
        sel++; len--;
        for (c = cl; *c; ) {
            while (*c == ' ') c++;
            cl_len = 0;
            while (c[cl_len] && c[cl_len] != ' ') cl_len++;
            if (cl_len == len && !memcmp(c, sel, len)) return 1;
            c += cl_len;
        }
        return 0;
    }
    if (*sel == '#') {
        const char *id = svg_attr(d, e, "id");
        return id && (int)strlen(id) == len - 1 && !memcmp(id, sel + 1, len - 1);
    }
    return (int)strlen(d->el[e].name) == len && !memcmp(d->el[e].name, sel, len);
}
static int svg_prop(struct svg_doc *d, int e, const char *name, char *out, int max)
{
    const char *st = svg_attr(d, e, "style"), *a;
    if (st && svg_decl(st, name, out, max)) return 1;
    if (d->style) {                                      /* a <style>'s rules */
        const char *s = d->style;
        int found = 0;
        while (*s) {
            const char *sel = s, *body;
            while (*s && *s != '{') s++;
            if (!*s) break;
            body = s + 1;
            if (*sel != '@') {
                const char *p = sel;
                while (p < s) {                          /* "a, b {": each */
                    const char *q = p;
                    while (q < s && *q != ',') q++;
                    if (svg_sel_match(d, e, p, q - p)) {
                        char tmp[160];
                        if (svg_decl(body, name, tmp, sizeof tmp)) { memcpy(out, tmp, max < 160 ? max : 160); out[max - 1] = 0; found = 1; }
                        break;
                    }
                    p = q + 1;
                }
            }
            while (*s && *s != '}') s++;
            if (*s) s++;
        }
        if (found) return 1;
    }
    if ((a = svg_attr(d, e, name))) {
        int k;
        for (k = 0; a[k] && k < max - 1; k++) out[k] = a[k];
        out[k] = 0;
        return 1;
    }
    return 0;
}

/* ---- the painter's state ---- */
struct svg_mx { float a, b, c, dd, e, f; };              /* x' = a x + c y + e, y' = b x + dd y + f */
struct svg_st {
    struct svg_mx m;
    unsigned fill, stroke, cur;
    int fill_a, stroke_a, has_fill, has_stroke, evenodd;
    float sw, opacity;
};

static struct svg_mx svg_mul(struct svg_mx p, struct svg_mx q)       /* p, then q inside it */
{
    struct svg_mx r;
    r.a = p.a * q.a + p.c * q.b;
    r.b = p.b * q.a + p.dd * q.b;
    r.c = p.a * q.c + p.c * q.dd;
    r.dd = p.b * q.c + p.dd * q.dd;
    r.e = p.a * q.e + p.c * q.f + p.e;
    r.f = p.b * q.e + p.dd * q.f + p.f;
    return r;
}
static struct svg_mx svg_transform(struct svg_mx m, const char *t)
{
    while (t && *t) {
        struct svg_mx k = { 1, 0, 0, 1, 0, 0 };
        float v[6] = { 0, 0, 0, 0, 0, 0 };
        int n = 0, which;
        while (*t == ' ' || *t == ',') t++;
        if (!memcmp(t, "matrix", 6)) which = 0;
        else if (!memcmp(t, "translate", 9)) which = 1;
        else if (!memcmp(t, "scale", 5)) which = 2;
        else if (!memcmp(t, "rotate", 6)) which = 3;
        else if (!memcmp(t, "skewX", 5)) which = 4;
        else if (!memcmp(t, "skewY", 5)) which = 5;
        else break;
        while (*t && *t != '(') t++;
        if (!*t) break;
        t++;
        while (n < 6) { const char *e = svg_num(t, &v[n]); if (!e) break; t = e; n++; }
        while (*t && *t != ')') t++;
        if (*t) t++;
        switch (which) {
        case 0: if (n == 6) { k.a = v[0]; k.b = v[1]; k.c = v[2]; k.dd = v[3]; k.e = v[4]; k.f = v[5]; } break;
        case 1: k.e = v[0]; k.f = n > 1 ? v[1] : 0; break;
        case 2: k.a = v[0]; k.dd = n > 1 ? v[1] : v[0]; break;
        case 3: {
            float r = v[0] * SVG_PI / 180, cs = svg_cos(r), sn = svg_sin(r);
            k.a = cs; k.b = sn; k.c = -sn; k.dd = cs;
            if (n == 3) {                                 /* about (cx, cy) */
                struct svg_mx t1 = { 1, 0, 0, 1, v[1], v[2] }, t2 = { 1, 0, 0, 1, -v[1], -v[2] };
                k = svg_mul(svg_mul(t1, k), t2);
            }
            break;
        }
        case 4: { float r = v[0] * SVG_PI / 180; k.c = svg_sin(r) / svg_cos(r); break; }
        case 5: { float r = v[0] * SVG_PI / 180; k.b = svg_sin(r) / svg_cos(r); break; }
        }
        m = svg_mul(m, k);
    }
    return m;
}

/* ---- edges, filled: scanlines, 5 a pixel ---- */
struct svg_edge { float x0, y0, x1, y1; int dir; };
struct svg_ras {
    int w, h;
    unsigned char *rgba;                                 /* the canvas */
    struct svg_edge *e;
    int ne, cap;
    float *cov;                                          /* a row's coverage */
    float px, py, sx, sy;                                /* the pen, where its figure began */
    int open;
};
static void svg_edge_add(struct svg_ras *r, float x0, float y0, float x1, float y1)
{
    struct svg_edge *e;
    if (y0 == y1) return;
    if (r->ne == r->cap) {
        int nc = r->cap ? r->cap * 2 : 256;
        struct svg_edge *n2 = realloc(r->e, nc * sizeof *n2);
        if (!n2) return;
        r->e = n2;
        r->cap = nc;
    }
    e = &r->e[r->ne++];
    if (y0 < y1) { e->x0 = x0; e->y0 = y0; e->x1 = x1; e->y1 = y1; e->dir = 1; }
    else { e->x0 = x1; e->y0 = y1; e->x1 = x0; e->y1 = y0; e->dir = -1; }
}
static void svg_fill(struct svg_ras *r, unsigned color, int alpha, int evenodd)
{
    int y, i, sub, ymin = r->h, ymax = 0;
    float xs[512];
    int ds[512];
    if (!r->ne || alpha <= 0) { r->ne = 0; return; }
    for (i = 0; i < r->ne; i++) {
        int a = (int)r->e[i].y0, b = (int)r->e[i].y1 + 1;
        if (a < ymin) ymin = a;
        if (b > ymax) ymax = b;
    }
    if (ymin < 0) ymin = 0;
    if (ymax > r->h) ymax = r->h;
    for (y = ymin; y < ymax; y++) {
        int x0 = r->w, x1 = -1;
        for (sub = 0; sub < 5; sub++) {
            float sy = y + (sub + 0.5f) / 5;
            int n = 0, j, wind = 0;
            for (i = 0; i < r->ne && n < 512; i++) {
                struct svg_edge *e = &r->e[i];
                if (sy < e->y0 || sy >= e->y1) continue;
                xs[n] = e->x0 + (sy - e->y0) * (e->x1 - e->x0) / (e->y1 - e->y0);
                ds[n++] = e->dir;
            }
            for (i = 1; i < n; i++) {                    /* in order */
                float xv = xs[i];
                int dv = ds[i];
                for (j = i; j > 0 && xs[j - 1] > xv; j--) { xs[j] = xs[j - 1]; ds[j] = ds[j - 1]; }
                xs[j] = xv; ds[j] = dv;
            }
            for (i = 0; i + 1 <= n; i++) {
                int inside;
                wind += evenodd ? 1 : ds[i];
                inside = evenodd ? (wind & 1) : wind != 0;
                if (inside && i + 1 < n) {               /* xs[i]..xs[i+1] covered */
                    float a = xs[i], b = xs[i + 1];
                    int ia, ib, k;
                    if (a < 0) a = 0;
                    if (b > r->w) b = r->w;
                    if (a >= b) continue;
                    ia = (int)a; ib = (int)b;
                    if (ia < x0) x0 = ia;
                    if (ib > x1) x1 = ib < r->w ? ib : r->w - 1;
                    if (ia == ib) { r->cov[ia] += (b - a) / 5; continue; }
                    r->cov[ia] += (ia + 1 - a) / 5;
                    for (k = ia + 1; k < ib; k++) r->cov[k] += 0.2f;
                    if (ib < r->w) r->cov[ib] += (b - ib) / 5;
                }
            }
        }
        for (i = x0; i <= x1 && i < r->w; i++) {          /* that row, painted */
            float c = r->cov[i];
            if (c > 0) {
                unsigned char *p = r->rgba + 4 * (y * r->w + i);
                int a = (int)((c > 1 ? 1 : c) * alpha), na;
                if (a > 0) {
                    na = a + p[3] * (255 - a) / 255;
                    if (na > 0) {
                        p[0] = (((color >> 16) & 255) * a + p[0] * p[3] * (255 - a) / 255) / na;
                        p[1] = (((color >> 8) & 255) * a + p[1] * p[3] * (255 - a) / 255) / na;
                        p[2] = ((color & 255) * a + p[2] * p[3] * (255 - a) / 255) / na;
                    }
                    p[3] = na;
                }
            }
            r->cov[i] = 0;
        }
    }
    r->ne = 0;
}

/* ---- figures: points in the element's own space, made the canvas's ---- */
#define SVG_PTS_MAX 65536
struct svg_poly { float *x, *y; int n, cap; int *starts, nst, stcap; int *closed; };
static void svg_pt(struct svg_poly *p, struct svg_mx *m, float x, float y)
{
    if (p->n == p->cap) {
        int nc = p->cap ? p->cap * 2 : 256;
        float *nx, *ny;
        if (nc > SVG_PTS_MAX) return;
        nx = realloc(p->x, nc * sizeof(float));
        if (!nx) return;
        p->x = nx;
        ny = realloc(p->y, nc * sizeof(float));
        if (!ny) return;
        p->y = ny;
        p->cap = nc;
    }
    p->x[p->n] = m->a * x + m->c * y + m->e;
    p->y[p->n] = m->b * x + m->dd * y + m->f;
    p->n++;
}
static void svg_begin(struct svg_poly *p)
{
    if (p->nst == p->stcap) {
        int nc = p->stcap ? p->stcap * 2 : 16;
        int *ns = realloc(p->starts, nc * sizeof(int)), *nc2;
        if (!ns) return;
        p->starts = ns;
        nc2 = realloc(p->closed, nc * sizeof(int));
        if (!nc2) return;
        p->closed = nc2;
        p->stcap = nc;
    }
    p->starts[p->nst] = p->n;
    p->closed[p->nst++] = 0;
}
static int svg_steps(struct svg_mx *m, float len)
{
    float s = svg_sqrt(m->a * m->a + m->b * m->b) * len / 3;
    int n = (int)s;
    return n < 4 ? 4 : n > 64 ? 64 : n;
}

/* path data -> figures */
static void svg_path(struct svg_poly *p, struct svg_mx *m, const char *d)
{
    float cx = 0, cy = 0, sx = 0, sy = 0, qx = 0, qy = 0;   /* (q: the last control point) */
    int cmd = 0, prev = 0;
    while (d && *d) {
        float v[7];
        int need, i, rel;
        while (svg_isspace(*d)) d++;
        if (!*d) break;
        if ((*d >= 'A' && *d <= 'Z') || (*d >= 'a' && *d <= 'z')) cmd = *d++;
        else if (!cmd) break;
        rel = cmd >= 'a';
        switch (svg_lower(cmd)) {
        case 'z':
            if (p->nst) p->closed[p->nst - 1] = 1;
            cx = sx; cy = sy;
            prev = 'z';
            continue;
        case 'm': case 'l': case 't': need = 2; break;
        case 'h': case 'v': need = 1; break;
        case 'c': need = 6; break;
        case 's': case 'q': need = 4; break;
        case 'a': need = 7; break;
        default: return;
        }
        for (i = 0; i < need; i++) {
            const char *e;
            while (svg_isspace(*d)) d++;
            if (svg_lower(cmd) == 'a' && (i == 3 || i == 4) && (*d == '0' || *d == '1')) {   /* flags: one digit */
                v[i] = *d++ - '0';
                continue;
            }
            if (!(e = svg_num(d, &v[i]))) return;
            d = e;
        }
        switch (svg_lower(cmd)) {
        case 'm':
            if (rel) { v[0] += cx; v[1] += cy; }
            cx = sx = v[0]; cy = sy = v[1];
            svg_begin(p);
            svg_pt(p, m, cx, cy);
            cmd = rel ? 'l' : 'L';                        /* (more pairs: lines) */
            prev = 'm';
            continue;
        case 'l':
            if (rel) { v[0] += cx; v[1] += cy; }
            cx = v[0]; cy = v[1];
            svg_pt(p, m, cx, cy);
            break;
        case 'h': cx = rel ? cx + v[0] : v[0]; svg_pt(p, m, cx, cy); break;
        case 'v': cy = rel ? cy + v[0] : v[0]; svg_pt(p, m, cx, cy); break;
        case 'c': case 's': case 'q': case 't': {
            float x1, y1, x2, y2, x, y;
            int k, steps, cubic = svg_lower(cmd) == 'c' || svg_lower(cmd) == 's';
            if (svg_lower(cmd) == 'c') {
                x1 = v[0]; y1 = v[1]; x2 = v[2]; y2 = v[3]; x = v[4]; y = v[5];
                if (rel) { x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy; }
            } else if (svg_lower(cmd) == 's') {
                x1 = (prev == 'c' || prev == 's') ? 2 * cx - qx : cx;
                y1 = (prev == 'c' || prev == 's') ? 2 * cy - qy : cy;
                x2 = v[0]; y2 = v[1]; x = v[2]; y = v[3];
                if (rel) { x2 += cx; y2 += cy; x += cx; y += cy; }
            } else if (svg_lower(cmd) == 'q') {
                x1 = v[0]; y1 = v[1]; x = v[2]; y = v[3];
                if (rel) { x1 += cx; y1 += cy; x += cx; y += cy; }
                x2 = x1; y2 = y1;
            } else {
                x1 = (prev == 'q' || prev == 't') ? 2 * cx - qx : cx;
                y1 = (prev == 'q' || prev == 't') ? 2 * cy - qy : cy;
                x = v[0]; y = v[1];
                if (rel) { x += cx; y += cy; }
                x2 = x1; y2 = y1;
            }
            {
                float dx = x - cx, dy = y - cy, l = svg_sqrt(dx * dx + dy * dy) + svg_sqrt((x1 - cx) * (x1 - cx) + (y1 - cy) * (y1 - cy));
                steps = svg_steps(m, l);
            }
            for (k = 1; k <= steps; k++) {
                float t = (float)k / steps, u = 1 - t, px, py;
                if (cubic) {
                    px = u * u * u * cx + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x;
                    py = u * u * u * cy + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y;
                } else {
                    px = u * u * cx + 2 * u * t * x1 + t * t * x;
                    py = u * u * cy + 2 * u * t * y1 + t * t * y;
                }
                svg_pt(p, m, px, py);
            }
            qx = cubic ? x2 : x1; qy = cubic ? y2 : y1;
            cx = x; cy = y;
            break;
        }
        case 'a': {                                       /* endpoint -> center (SVG's F.6.5) */
            float rx = v[0] < 0 ? -v[0] : v[0], ry = v[1] < 0 ? -v[1] : v[1], phi = v[2] * SVG_PI / 180;
            int large = v[3] != 0, sweep = v[4] != 0, k, steps;
            float x = v[5], y = v[6], cs, sn, x1p, y1p, lam, sq, num, den, cxp, cyp, ccx, ccy, t1, dt;
            if (rel) { x += cx; y += cy; }
            if (rx < 1e-6f || ry < 1e-6f) { cx = x; cy = y; svg_pt(p, m, cx, cy); break; }
            cs = svg_cos(phi); sn = svg_sin(phi);
            x1p = cs * (cx - x) / 2 + sn * (cy - y) / 2;
            y1p = -sn * (cx - x) / 2 + cs * (cy - y) / 2;
            lam = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry);
            if (lam > 1) { float s = svg_sqrt(lam); rx *= s; ry *= s; }
            num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
            den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
            sq = den > 0 && num > 0 ? svg_sqrt(num / den) : 0;
            if (large == sweep) sq = -sq;
            cxp = sq * rx * y1p / ry;
            cyp = -sq * ry * x1p / rx;
            ccx = cs * cxp - sn * cyp + (cx + x) / 2;
            ccy = sn * cxp + cs * cyp + (cy + y) / 2;
            t1 = svg_atan2((y1p - cyp) / ry, (x1p - cxp) / rx);
            dt = svg_atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx) - t1;
            if (sweep && dt < 0) dt += 2 * SVG_PI;
            if (!sweep && dt > 0) dt -= 2 * SVG_PI;
            steps = svg_steps(m, (rx > ry ? rx : ry) * (dt < 0 ? -dt : dt));
            for (k = 1; k <= steps; k++) {
                float a = t1 + dt * k / steps, ex = rx * svg_cos(a), ey = ry * svg_sin(a);
                svg_pt(p, m, cs * ex - sn * ey + ccx, sn * ex + cs * ey + ccy);
            }
            cx = x; cy = y;
            break;
        }
        }
        prev = svg_lower(cmd);
    }
}

static void svg_ellipse(struct svg_poly *p, struct svg_mx *m, float cx, float cy, float rx, float ry)
{
    int k, steps = svg_steps(m, 2 * SVG_PI * (rx > ry ? rx : ry));
    if (steps < 12) steps = 12;
    svg_begin(p);
    for (k = 0; k < steps; k++) {
        float a = 2 * SVG_PI * k / steps;
        svg_pt(p, m, cx + rx * svg_cos(a), cy + ry * svg_sin(a));
    }
    p->closed[p->nst - 1] = 1;
}

/* the figures' insides -> edges */
static void svg_fill_edges(struct svg_ras *r, struct svg_poly *p)
{
    int f;
    for (f = 0; f < p->nst; f++) {
        int a = p->starts[f], b = f + 1 < p->nst ? p->starts[f + 1] : p->n, i;
        if (b - a < 2) continue;
        for (i = a; i + 1 < b; i++) svg_edge_add(r, p->x[i], p->y[i], p->x[i + 1], p->y[i + 1]);
        svg_edge_add(r, p->x[b - 1], p->y[b - 1], p->x[a], p->y[a]);   /* (filled: closed anyway) */
    }
}
/* a quad / disc, turned the same way (so nonzero joins them) */
static void svg_quad(struct svg_ras *r, float *x, float *y, int n)
{
    float area = 0;
    int i;
    for (i = 0; i < n; i++) area += x[i] * y[(i + 1) % n] - x[(i + 1) % n] * y[i];
    if (area < 0)
        for (i = 0; i < n; i++) svg_edge_add(r, x[i], y[i], x[(i + 1) % n], y[(i + 1) % n]);
    else
        for (i = n - 1; i >= 0; i--) svg_edge_add(r, x[(i + 1) % n], y[(i + 1) % n], x[i], y[i]);
}
/* the figures' outlines (width sw on the canvas) -> edges */
static void svg_stroke_edges(struct svg_ras *r, struct svg_poly *p, float sw)
{
    int f;
    float hw = sw / 2;
    if (hw < 0.35f) hw = 0.35f;
    for (f = 0; f < p->nst; f++) {
        int a = p->starts[f], b = f + 1 < p->nst ? p->starts[f + 1] : p->n, i, last = p->closed[f] ? b : b - 1;
        for (i = a; i < last; i++) {
            int j = i + 1 < b ? i + 1 : a;
            float dx = p->x[j] - p->x[i], dy = p->y[j] - p->y[i], l = svg_sqrt(dx * dx + dy * dy), qx[4], qy[4], nx, ny;
            if (l < 1e-4f) continue;
            nx = -dy / l * hw; ny = dx / l * hw;
            qx[0] = p->x[i] + nx; qy[0] = p->y[i] + ny;
            qx[1] = p->x[j] + nx; qy[1] = p->y[j] + ny;
            qx[2] = p->x[j] - nx; qy[2] = p->y[j] - ny;
            qx[3] = p->x[i] - nx; qy[3] = p->y[i] - ny;
            svg_quad(r, qx, qy, 4);
            if (hw > 0.9f) {                             /* the joins: round */
                float cxs[10], cys[10];
                int k;
                for (k = 0; k < 10; k++) { cxs[k] = p->x[j] + hw * svg_cos(k * SVG_PI / 5); cys[k] = p->y[j] + hw * svg_sin(k * SVG_PI / 5); }
                svg_quad(r, cxs, cys, 10);
            }
        }
    }
}

/* ---- drawing the tree ---- */
static unsigned svg_stop_color(struct svg_doc *d, const char *url, unsigned cur, int *a)
{
    char id[64];
    int k = 0, i, best = -1, cnt = 0;
    unsigned c = 0x808080;
    while (*url && *url != '#') url++;
    if (*url) url++;
    while (url[k] && url[k] != ')' && url[k] != '"' && url[k] != '\'' && k < 63) { id[k] = url[k]; k++; }
    id[k] = 0;
    *a = 255;
    for (i = 0; i < d->n; i++) {
        const char *ia = svg_attr(d, i, "id");
        if (ia && !strcmp(ia, id)) { best = i; break; }
    }
    if (best < 0) return c;
    {                                                    /* (href'd gradients: their stops) */
        const char *h = svg_attr(d, best, "href");
        if (!d->el[best].first || d->el[best].first < 0) { if (h && *h == '#') return svg_stop_color(d, h, cur, a); }
    }
    for (i = d->el[best].first; i >= 0; i = d->el[i].next) {
        if (!strcmp(d->el[i].name, "stop")) {            /* the middle stop's color */
            char v[64];
            unsigned sc;
            int sa;
            cnt++;
            if (svg_prop(d, i, "stop-color", v, sizeof v) && svg_color(v, cur, &sc, &sa) == 1) {
                if (cnt == 1 || cnt <= 2) { c = sc; *a = sa; }
            }
        }
    }
    return c;
}

static void svg_paint(struct svg_doc *d, int e, struct svg_ras *r, struct svg_st st, int depth);

/* an element's own fill/stroke/... over what it inherited */
static int svg_style(struct svg_doc *d, int e, struct svg_st *st)
{
    char v[160];
    unsigned c;
    int a;
    if (svg_prop(d, e, "display", v, sizeof v) && !strcmp(v, "none")) return 0;
    if (svg_prop(d, e, "visibility", v, sizeof v) && !strcmp(v, "hidden")) return 0;
    if (svg_prop(d, e, "color", v, sizeof v) && svg_color(v, st->cur, &c, &a) == 1) st->cur = c;
    if (svg_prop(d, e, "fill", v, sizeof v)) {
        int k = svg_color(v, st->cur, &c, &a);
        if (k == 2) st->has_fill = 0;
        else if (k == 1) { st->has_fill = 1; st->fill = c; st->fill_a = a; }
        else if (!memcmp(v, "url(", 4)) { st->has_fill = 1; st->fill = svg_stop_color(d, v, st->cur, &st->fill_a); }
    }
    if (svg_prop(d, e, "stroke", v, sizeof v)) {
        int k = svg_color(v, st->cur, &c, &a);
        if (k == 2) st->has_stroke = 0;
        else if (k == 1) { st->has_stroke = 1; st->stroke = c; st->stroke_a = a; }
        else if (!memcmp(v, "url(", 4)) { st->has_stroke = 1; st->stroke = svg_stop_color(d, v, st->cur, &st->stroke_a); }
    }
    if (svg_prop(d, e, "stroke-width", v, sizeof v)) st->sw = svg_len(v, 1, st->sw);
    if (svg_prop(d, e, "fill-rule", v, sizeof v)) st->evenodd = !strcmp(v, "evenodd");
    if (svg_prop(d, e, "opacity", v, sizeof v)) { float o = svg_len(v, 1, 1); st->opacity *= o; }
    if (svg_prop(d, e, "fill-opacity", v, sizeof v)) st->fill_a = (int)(st->fill_a * svg_len(v, 1, 1));
    if (svg_prop(d, e, "stroke-opacity", v, sizeof v)) st->stroke_a = (int)(st->stroke_a * svg_len(v, 1, 1));
    {
        const char *t = svg_attr(d, e, "transform");
        if (t) st->m = svg_transform(st->m, t);
    }
    return 1;
}

static void svg_shape(struct svg_doc *d, int e, struct svg_ras *r, struct svg_st *st)
{
    struct svg_poly p;
    const char *n = d->el[e].name;
    memset(&p, 0, sizeof p);
#define A(x) svg_len(svg_attr(d, e, x), 100, 0)
    if (!strcmp(n, "path")) svg_path(&p, &st->m, svg_attr(d, e, "d"));
    else if (!strcmp(n, "rect")) {
        float x = A("x"), y = A("y"), w = A("width"), h = A("height"), rx = A("rx"), ry = A("ry");
        if (w <= 0 || h <= 0) return;
        if (rx <= 0) rx = ry;
        if (ry <= 0) ry = rx;
        if (rx > w / 2) rx = w / 2;
        if (ry > h / 2) ry = h / 2;
        svg_begin(&p);
        if (rx <= 0) {
            svg_pt(&p, &st->m, x, y); svg_pt(&p, &st->m, x + w, y);
            svg_pt(&p, &st->m, x + w, y + h); svg_pt(&p, &st->m, x, y + h);
        } else {
            int k, c;
            static const float cxs[4] = { 1, 1, 0, 0 }, cys[4] = { 0, 1, 1, 0 };
            for (c = 0; c < 4; c++) {                     /* each corner a quarter */
                float ccx = cxs[c] ? x + w - rx : x + rx, ccy = cys[c] ? y + h - ry : y + ry;
                for (k = 0; k <= 6; k++) {
                    float a = (c * 90 - 90 + k * 15) * SVG_PI / 180;
                    svg_pt(&p, &st->m, ccx + rx * svg_cos(a), ccy + ry * svg_sin(a));
                }
            }
        }
        p.closed[0] = 1;
    } else if (!strcmp(n, "circle")) {
        float rr = A("r");
        if (rr <= 0) return;
        svg_ellipse(&p, &st->m, A("cx"), A("cy"), rr, rr);
    } else if (!strcmp(n, "ellipse")) {
        float rx = A("rx"), ry = A("ry");
        if (rx <= 0 || ry <= 0) return;
        svg_ellipse(&p, &st->m, A("cx"), A("cy"), rx, ry);
    } else if (!strcmp(n, "line")) {
        svg_begin(&p);
        svg_pt(&p, &st->m, A("x1"), A("y1"));
        svg_pt(&p, &st->m, A("x2"), A("y2"));
    } else if (!strcmp(n, "polyline") || !strcmp(n, "polygon")) {
        const char *s = svg_attr(d, e, "points");
        float x, y;
        svg_begin(&p);
        while (s && (s = svg_num(s, &x)) && (s = svg_num(s, &y))) svg_pt(&p, &st->m, x, y);
        if (n[4] == 'g') p.closed[0] = 1;
    }
#undef A
    if (p.n >= 2) {
        float scale = svg_sqrt(st->m.a * st->m.a + st->m.b * st->m.b);
        if (st->has_fill && strcmp(n, "line") && strcmp(n, "polyline")) {
            svg_fill_edges(r, &p);
            svg_fill(r, st->fill, (int)(st->fill_a * st->opacity), st->evenodd);
        } else if (st->has_fill && !strcmp(n, "polyline")) {
            svg_fill_edges(r, &p);
            svg_fill(r, st->fill, (int)(st->fill_a * st->opacity), st->evenodd);
        }
        if (st->has_stroke && st->sw > 0) {
            svg_stroke_edges(r, &p, st->sw * scale);
            svg_fill(r, st->stroke, (int)(st->stroke_a * st->opacity), 0);
        }
    }
    free(p.x); free(p.y); free(p.starts); free(p.closed);
}

static int svg_by_id(struct svg_doc *d, const char *href)
{
    int i;
    if (!href || *href != '#') return -1;
    href++;
    for (i = 0; i < d->n; i++) {
        const char *ia = svg_attr(d, i, "id");
        if (ia && !strcmp(ia, href)) return i;
    }
    return -1;
}

/* the viewBox of e (an <svg> or <symbol>) into w x h at x, y */
static struct svg_mx svg_viewbox(struct svg_doc *d, int e, struct svg_mx m, float x, float y, float w, float h)
{
    const char *vb = svg_attr(d, e, "viewbox"), *par = svg_attr(d, e, "preserveaspectratio");
    float v[4];
    struct svg_mx k = { 1, 0, 0, 1, 0, 0 };
    k.e = x; k.f = y;
    if (vb && (vb = svg_num(vb, &v[0])) && (vb = svg_num(vb, &v[1])) && (vb = svg_num(vb, &v[2])) && svg_num(vb, &v[3]) &&
        v[2] > 0 && v[3] > 0 && w > 0 && h > 0) {
        float sx = w / v[2], sy = h / v[3];
        if (!par || memcmp(par, "none", 4)) {            /* meet, centered */
            float s = sx < sy ? sx : sy;
            int slice = 0;
            const char *q = par;
            while (q && *q) { if (!memcmp(q, "slice", 5)) slice = 1; q++; }
            if (slice) s = sx > sy ? sx : sy;
            k.e += (w - v[2] * s) / 2 - v[0] * s;
            k.f += (h - v[3] * s) / 2 - v[1] * s;
            sx = sy = s;
        } else { k.e -= v[0] * sx; k.f -= v[1] * sy; }
        k.a = sx; k.dd = sy;
    }
    return svg_mul(m, k);
}

static void svg_children(struct svg_doc *d, int e, struct svg_ras *r, struct svg_st st, int depth)
{
    int c;
    for (c = d->el[e].first; c >= 0; c = d->el[c].next) svg_paint(d, c, r, st, depth + 1);
}

static void svg_paint(struct svg_doc *d, int e, struct svg_ras *r, struct svg_st st, int depth)
{
    const char *n = d->el[e].name;
    if (depth > 24) return;
    if (!strcmp(n, "defs") || !strcmp(n, "symbol") || !strcmp(n, "clippath") || !strcmp(n, "mask") ||
        !strcmp(n, "lineargradient") || !strcmp(n, "radialgradient") || !strcmp(n, "pattern") || !strcmp(n, "style") ||
        !strcmp(n, "title") || !strcmp(n, "desc") || !strcmp(n, "metadata") || !strcmp(n, "text") || !strcmp(n, "filter") ||
        !strcmp(n, "marker") || !strcmp(n, "foreignobject") || !strcmp(n, "image") || !strcmp(n, "script")) return;
    if (!svg_style(d, e, &st)) return;
    if (!strcmp(n, "g") || !strcmp(n, "a") || !strcmp(n, "switch")) { svg_children(d, e, r, st, depth); return; }
    if (!strcmp(n, "svg")) {                             /* (inside another) */
        float w = svg_len(svg_attr(d, e, "width"), 100, 100), h = svg_len(svg_attr(d, e, "height"), 100, 100);
        st.m = svg_viewbox(d, e, st.m, svg_len(svg_attr(d, e, "x"), 100, 0), svg_len(svg_attr(d, e, "y"), 100, 0), w, h);
        svg_children(d, e, r, st, depth);
        return;
    }
    if (!strcmp(n, "use")) {
        int t = svg_by_id(d, svg_attr(d, e, "href"));
        struct svg_mx k = { 1, 0, 0, 1, 0, 0 };
        if (t < 0 || t == e) return;
        k.e = svg_len(svg_attr(d, e, "x"), 100, 0);
        k.f = svg_len(svg_attr(d, e, "y"), 100, 0);
        st.m = svg_mul(st.m, k);
        if (!strcmp(d->el[t].name, "symbol")) {
            float w = svg_len(svg_attr(d, e, "width"), 100, 0), h = svg_len(svg_attr(d, e, "height"), 100, 0);
            const char *vb = svg_attr(d, t, "viewbox");
            float v[4];
            if ((w <= 0 || h <= 0) && vb && (vb = svg_num(vb, &v[0])) && (vb = svg_num(vb, &v[1])) && (vb = svg_num(vb, &v[2])) && svg_num(vb, &v[3])) {
                if (w <= 0) w = v[2];
                if (h <= 0) h = v[3];
            }
            if (!svg_style(d, t, &st)) return;
            st.m = svg_viewbox(d, t, st.m, 0, 0, w, h);
            svg_children(d, t, r, st, depth);
        } else svg_paint(d, t, r, st, depth + 1);
        return;
    }
    svg_shape(d, e, r, &st);
}

static void svg_free(struct svg_doc *d) { free(d->el); free(d->text); free(d->style); }

/* its own size (width/height, or its viewBox's) */
static int svg_size(const char *src, int n, int *pw, int *ph)
{
    struct svg_doc d;
    int root, ok = 0;
    memset(&d, 0, sizeof d);
    if (svg_parse(&d, src, n)) {
        float w, h, v[4];
        const char *vb;
        for (root = 0; root < d.n && strcmp(d.el[root].name, "svg"); root++) ;
        vb = svg_attr(&d, root, "viewbox");
        if (!(vb && (vb = svg_num(vb, &v[0])) && (vb = svg_num(vb, &v[1])) && (vb = svg_num(vb, &v[2])) && svg_num(vb, &v[3])))
            v[2] = v[3] = 0;
        w = svg_len(svg_attr(&d, root, "width"), v[2] ? v[2] : 300, 0);
        h = svg_len(svg_attr(&d, root, "height"), v[3] ? v[3] : 150, 0);
        if (w <= 0 && v[2] > 0) w = h > 0 && v[3] > 0 ? h * v[2] / v[3] : v[2];
        if (h <= 0 && v[3] > 0) h = w > 0 && v[2] > 0 ? w * v[3] / v[2] : v[3];
        if (w <= 0) w = 300;
        if (h <= 0) h = 150;
        *pw = (int)(w + 0.5f);
        *ph = (int)(h + 0.5f);
        ok = 1;
    }
    svg_free(&d);
    return ok;
}

static unsigned *svg_render(const char *src, int n, int want_w, int want_h, unsigned bg, unsigned color, int *pw, int *ph)
{
    struct svg_doc d;
    struct svg_ras r;
    struct svg_st st;
    unsigned *out = 0;
    int root, w, h, i;
    if (!svg_size(src, n, &w, &h)) return 0;
    if (want_w > 0 && want_h <= 0) { want_h = (int)((float)h * want_w / (w ? w : 1)); }
    else if (want_h > 0 && want_w <= 0) { want_w = (int)((float)w * want_h / (h ? h : 1)); }
    if (want_w > 0) w = want_w;
    if (want_h > 0) h = want_h;
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    if (w > 2048) { h = h * 2048 / w; w = 2048; }
    if (h > 2048) { w = w * 2048 / h; h = 2048; }
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    memset(&d, 0, sizeof d);
    memset(&r, 0, sizeof r);
    if (!svg_parse(&d, src, n)) { svg_free(&d); return 0; }
    for (root = 0; root < d.n && strcmp(d.el[root].name, "svg"); root++) ;
    r.w = w; r.h = h;
    r.rgba = malloc(w * h * 4);
    r.cov = malloc((w + 1) * sizeof(float));
    out = malloc(w * h * 4);
    if (!r.rgba || !r.cov || !out) { free(out); out = 0; goto done; }
    memset(r.rgba, 0, w * h * 4);
    for (i = 0; i <= w; i++) r.cov[i] = 0;
    memset(&st, 0, sizeof st);
    st.m.a = st.m.dd = 1;
    st.has_fill = 1; st.fill = 0; st.fill_a = 255;
    st.stroke_a = 255;
    st.sw = 1;
    st.opacity = 1;
    st.cur = color;
    if (!svg_style(&d, root, &st)) goto paint_done;
    st.m = svg_viewbox(&d, root, st.m, 0, 0, w, h);
    {                                                    /* (no viewBox: its width/height as the units) */
        const char *vb = svg_attr(&d, root, "viewbox");
        if (!vb) {
            int ow, oh;
            if (svg_size(src, n, &ow, &oh) && ow > 0 && oh > 0) { st.m.a = (float)w / ow; st.m.dd = (float)h / oh; }
        }
    }
    svg_children(&d, root, &r, st, 0);
paint_done:
    for (i = 0; i < w * h; i++) {                        /* over the background */
        unsigned char *p = r.rgba + 4 * i;
        unsigned a = p[3];
        out[i] = ((p[0] * a + ((bg >> 16) & 255) * (255 - a)) / 255) << 16 |
                 ((p[1] * a + ((bg >> 8) & 255) * (255 - a)) / 255) << 8 |
                 ((p[2] * a + (bg & 255) * (255 - a)) / 255);
    }
    *pw = w;
    *ph = h;
done:
    free(r.rgba); free(r.cov); free(r.e);
    svg_free(&d);
    return out;
}

#endif
