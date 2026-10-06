/* dom.h - LexOS Web's document: the page's HTML read into a tree of
 * elements and text (what the layout walks, what CSS matches, what
 * JavaScript changes), and written back out (innerHTML).
 *
 * Nodes live in one array (dn[], index 0 unused): an element's tag and
 * attribute names are atoms (small numbers, the known tags first, see
 * TAG_NAMES), all text and attribute values UTF-8 in one pool (dstr).
 * dom_parse(buf, n, cs, parent) builds the tree from HTML in charset cs
 * (CS_* of browser.c, whose dec()/entities this uses): the page itself
 * into a new document, or a fragment (innerHTML) under parent - with
 * the end tags HTML lets a page leave out (<p>, <li>, <td>, <tr>,
 * <option>...) put in, <script>/<style>/<textarea>/<title> read as text,
 * and <svg> kept whole, as text, for svg.h to draw. */
#ifndef DOM_H
#define DOM_H

enum { DN_ELEM = 1, DN_TEXT = 3, DN_COMMENT = 8, DN_DOC = 9, DN_FRAG = 11 };
#define DF_SVG    1                       /* an <svg>: its source in text/tlen */
#define DF_NEW    2                       /* (made by JavaScript) */
#define DF_TPL    4                       /* <template>: not shown */

struct dnode {
    unsigned char type, flags;
    unsigned short tag;                   /* an atom */
    int parent, first, last, prev, next;
    int attr, nattr, acap;                /* its attributes: da[attr .. attr + nattr) */
    int text, tlen;                       /* DN_TEXT (and an <svg>'s source): in dstr */
    int ctrl;                             /* a form's field: ctrls[] (-1: none) */
    int js;                               /* its JavaScript object (0: none yet) */
    void *cs;                             /* its computed style (css.h), this layout's */
    int bx, by, bw, bh;                   /* where the last layout put it */
    int mgen, minw, maxw;                 /* its widths, measured (in layout mgen) */
};
struct dattr { int name, val; };          /* an atom; a string in dstr */

static struct dnode *dn;
static int ndn, dn_cap;
static struct dattr *da;
static int nda, da_cap;
static char *dstr;
static int ndstr, dstr_cap;
static int dom_doc, dom_html, dom_head, dom_body;
static int dom_gen;                       /* (changed: one more - JavaScript's) */

/* ---- atoms ---- */
#define TAG_NAMES \
    X(html) X(head) X(body) X(title) X(meta) X(link) X(style) X(script) X(noscript) X(template) X(base) \
    X(div) X(span) X(p) X(a) X(img) X(br) X(hr) X(h1) X(h2) X(h3) X(h4) X(h5) X(h6) X(ul) X(ol) X(li) X(dl) \
    X(dt) X(dd) X(table) X(caption) X(thead) X(tbody) X(tfoot) X(tr) X(td) X(th) X(col) X(colgroup) X(form) \
    X(input) X(textarea) X(select) X(option) X(optgroup) X(button) X(label) X(fieldset) X(legend) X(pre) \
    X(code) X(blockquote) X(b) X(strong) X(i) X(em) X(u) X(s) X(strike) X(del) X(ins) X(small) X(big) X(sub) \
    X(sup) X(font) X(center) X(nav) X(header) X(footer) X(main) X(section) X(article) X(aside) X(figure) \
    X(figcaption) X(address) X(svg) X(math) X(iframe) X(video) X(audio) X(canvas) X(object) X(embed) X(source) \
    X(picture) X(track) X(param) X(area) X(map) X(wbr) X(nobr) X(details) X(summary) X(dialog) X(menu) X(dir) \
    X(tt) X(kbd) X(samp) X(var) X(cite) X(dfn) X(abbr) X(q) X(mark) X(time) X(xmp) X(listing) X(plaintext) \
    X(frameset) X(frame) X(noframes) X(marquee) X(applet) X(hgroup) X(search) X(output) X(progress) X(meter) \
    X(datalist) X(keygen) X(ruby) X(rt) X(rp) X(bdi) X(bdo) X(data) X(slot)
#define X(n) T_##n,
enum { T_NONE, TAG_NAMES T_KNOWN };
#undef X
#define X(n) #n,
static const char *tag_names[] = { "", TAG_NAMES 0 };
#undef X

#define ATOM_BUCKETS 4096
static int *atom_off;                     /* atom -> its name in atom_pool */
static int natoms, atom_cap;
static char *atom_pool;
static int natom_pool, atom_pool_cap;
static int atom_hash[ATOM_BUCKETS], *atom_next;

static unsigned dom_hash(const char *s, int n)
{
    unsigned h = 2166136261u;
    while (n--) h = (h ^ (unsigned char)*s++) * 16777619u;
    return h;
}
static const char *atom_name(int a) { return a > 0 && a < natoms ? atom_pool + atom_off[a] : ""; }
/* name (n bytes, lowercased already) -> its atom; 0 if not known and !add */
static int atom_get(const char *s, int n, int add)
{
    unsigned h = dom_hash(s, n) & (ATOM_BUCKETS - 1);
    int a;
    for (a = atom_hash[h]; a; a = atom_next[a]) {
        const char *t = atom_pool + atom_off[a];
        if (!memcmp(t, s, n) && !t[n]) return a;
    }
    if (!add) return 0;
    if (natoms + 1 > atom_cap) {
        int nc = atom_cap ? atom_cap * 2 : 1024, *no = realloc(atom_off, nc * sizeof(int)), *nn;
        if (!no) return 0;
        atom_off = no;
        nn = realloc(atom_next, nc * sizeof(int));
        if (!nn) return 0;
        atom_next = nn;
        atom_cap = nc;
    }
    if (natom_pool + n + 1 > atom_pool_cap) {
        int nc = atom_pool_cap ? atom_pool_cap * 2 : 16384;
        char *np;
        while (nc < natom_pool + n + 1) nc *= 2;
        np = realloc(atom_pool, nc);
        if (!np) return 0;
        atom_pool = np;
        atom_pool_cap = nc;
    }
    if (!natoms) natoms = 1;                             /* (0: none) */
    a = natoms++;
    atom_off[a] = natom_pool;
    memcpy(atom_pool + natom_pool, s, n);
    atom_pool[natom_pool + n] = 0;
    natom_pool += n + 1;
    atom_next[a] = atom_hash[h];
    atom_hash[h] = a;
    return a;
}
static int atom_of(const char *s) { return atom_get(s, strlen(s), 1); }
/* a name in any case -> its atom (lowercased) */
static int atom_lc(const char *s, int n, int add)
{
    char t[64];
    int i;
    if (n > 63) n = 63;
    for (i = 0; i < n; i++) t[i] = s[i] >= 'A' && s[i] <= 'Z' ? s[i] + 32 : s[i];
    return atom_get(t, n, add);
}
static void atoms_init(void)
{
    int i;
    if (natoms) return;
    for (i = 1; tag_names[i]; i++) atom_of(tag_names[i]);              /* (T_x == its atom) */
}

/* ---- strings ---- */
static int dom_room(int need);
static int dom_str(const char *s, int n)
{
    int at;
    if (!dom_room(n)) return 0;                          /* (0: "") */
    at = ndstr;
    memcpy(dstr + at, s, n);
    dstr[at + n] = 0;
    ndstr += n + 1;
    return at;
}
static int dom_utf8(unsigned u, char *o)
{
    if (u < 0x80) { o[0] = u; return 1; }
    if (u < 0x800) { o[0] = 0xC0 | u >> 6; o[1] = 0x80 | (u & 63); return 2; }
    if (u < 0x10000) { o[0] = 0xE0 | u >> 12; o[1] = 0x80 | (u >> 6 & 63); o[2] = 0x80 | (u & 63); return 3; }
    o[0] = 0xF0 | (u >> 18 & 7); o[1] = 0x80 | (u >> 12 & 63); o[2] = 0x80 | (u >> 6 & 63); o[3] = 0x80 | (u & 63);
    return 4;
}
/* the next character of UTF-8 text */
static unsigned dom_u8(const char *s, int n, int *p)
{
    unsigned c = (unsigned char)s[*p], u;
    int k;
    (*p)++;
    if (c < 0x80) return c;
    if ((c & 0xE0) == 0xC0) { u = c & 0x1F; k = 1; }
    else if ((c & 0xF0) == 0xE0) { u = c & 0x0F; k = 2; }
    else if ((c & 0xF8) == 0xF0) { u = c & 0x07; k = 3; }
    else return 0xFFFD;
    while (k-- && *p < n && (s[*p] & 0xC0) == 0x80) u = u << 6 | (s[(*p)++] & 0x3F);
    return u;
}

/* ---- nodes ---- */
static void dom_free(void)
{
    free(dn); free(da); free(dstr);
    dn = 0; da = 0; dstr = 0;
    ndn = dn_cap = nda = da_cap = ndstr = dstr_cap = 0;
    dom_doc = dom_html = dom_head = dom_body = 0;
}
static int dom_new(int type, int tag)
{
    struct dnode *d;
    if (ndn + 1 > dn_cap) {
        int nc = dn_cap ? dn_cap * 2 : 1024;
        struct dnode *nd;
        if (nc > 2000000) return 0;
        nd = realloc(dn, nc * sizeof *nd);
        if (!nd) return 0;
        dn = nd;
        dn_cap = nc;
    }
    if (!ndn) { memset(&dn[0], 0, sizeof dn[0]); ndn = 1; }
    d = &dn[ndn];
    memset(d, 0, sizeof *d);
    d->type = type;
    d->tag = tag;
    d->ctrl = -1;
    return ndn++;
}
static void dom_unlink(int c)
{
    struct dnode *n = &dn[c];
    if (!n->parent) return;
    if (n->prev) dn[n->prev].next = n->next; else dn[n->parent].first = n->next;
    if (n->next) dn[n->next].prev = n->prev; else dn[n->parent].last = n->prev;
    n->parent = n->prev = n->next = 0;
    dom_gen++;
}
/* c put into p before ref (0: last) */
static void dom_insert(int p, int c, int ref)
{
    if (!p || !c || p == c) return;
    if (dn[c].parent) dom_unlink(c);
    dn[c].parent = p;
    if (!ref || dn[ref].parent != p) {
        dn[c].prev = dn[p].last;
        dn[c].next = 0;
        if (dn[p].last) dn[dn[p].last].next = c; else dn[p].first = c;
        dn[p].last = c;
    } else {
        dn[c].next = ref;
        dn[c].prev = dn[ref].prev;
        if (dn[ref].prev) dn[dn[ref].prev].next = c; else dn[p].first = c;
        dn[ref].prev = c;
    }
    dom_gen++;
}
static int dom_elem(int tag, int parent)
{
    int e = dom_new(DN_ELEM, tag);
    if (e && parent) dom_insert(parent, e, 0);
    return e;
}
static int dom_room(int need)
{
    if (ndstr + need + 2 > dstr_cap) {
        int nc = dstr_cap ? dstr_cap * 2 : 65536;
        char *np;
        while (nc < ndstr + need + 2) nc *= 2;
        np = realloc(dstr, nc);
        if (!np) return 0;
        dstr = np;
        dstr_cap = nc;
    }
    if (!ndstr) dstr[ndstr++] = 0;
    return 1;
}
static int dom_text(const char *s, int n, int parent)
{
    int t;
    if (parent && dn[parent].last && dn[dn[parent].last].type == DN_TEXT) {        /* (joined to the last) */
        struct dnode *l = &dn[dn[parent].last];
        if (!dom_room(l->tlen + n + 2)) return 0;
        if (l->text + l->tlen + 1 != ndstr) {            /* (moved to the pool's end first) */
            int at = ndstr;
            memcpy(dstr + at, dstr + l->text, l->tlen);
            ndstr += l->tlen;
            dstr[ndstr++] = 0;
            l->text = at;
        }
        ndstr--;
        memcpy(dstr + ndstr, s, n);
        ndstr += n;
        dstr[ndstr++] = 0;
        l->tlen += n;
        return dn[parent].last;
    }
    t = dom_new(DN_TEXT, 0);
    if (!t) return 0;
    dn[t].text = dom_str(s, n);
    dn[t].tlen = n;
    if (parent) dom_insert(parent, t, 0);
    return t;
}

/* ---- attributes ---- */
static int dom_attr_at(int e, int name)
{
    int i;
    if (!e || dn[e].type != DN_ELEM) return -1;
    for (i = 0; i < dn[e].nattr; i++) if (da[dn[e].attr + i].name == name) return dn[e].attr + i;
    return -1;
}
static const char *dom_attr_a(int e, int name)
{
    int i = dom_attr_at(e, name);
    return i < 0 ? 0 : dstr + da[i].val;
}
static const char *dom_attr(int e, const char *name)
{
    int a = atom_get(name, strlen(name), 0);
    return a ? dom_attr_a(e, a) : 0;
}
static void dom_set_attr_a(int e, int name, const char *v, int vn)
{
    int i = dom_attr_at(e, name);
    if (!name) return;
    if (i >= 0) { da[i].val = dom_str(v, vn); dom_gen++; return; }
    if (dn[e].nattr == dn[e].acap) {                     /* (moved to the end, room for more) */
        int nc = dn[e].acap ? dn[e].acap * 2 : 4, k;
        if (nda + nc > da_cap) {
            int c2 = da_cap ? da_cap * 2 : 4096;
            struct dattr *n2;
            while (c2 < nda + nc) c2 *= 2;
            n2 = realloc(da, c2 * sizeof *n2);
            if (!n2) return;
            da = n2;
            da_cap = c2;
        }
        for (k = 0; k < dn[e].nattr; k++) da[nda + k] = da[dn[e].attr + k];
        dn[e].attr = nda;
        nda += nc;
        dn[e].acap = nc;
    }
    da[dn[e].attr + dn[e].nattr].name = name;
    da[dn[e].attr + dn[e].nattr].val = dom_str(v, vn);
    dn[e].nattr++;
    dom_gen++;
}
static void dom_set_attr(int e, const char *name, const char *v)
{
    dom_set_attr_a(e, atom_lc(name, strlen(name), 1), v, strlen(v));
}
static void dom_del_attr(int e, int name)
{
    int i = dom_attr_at(e, name);
    if (i < 0) return;
    da[i] = da[dn[e].attr + dn[e].nattr - 1];
    dn[e].nattr--;
    dom_gen++;
}

/* ---- the text of a node and all inside it (UTF-8, malloc'd) ---- */
static void dom_text_walk(int n, char **b, int *len, int *cap)
{
    int c;
    if (dn[n].type == DN_TEXT) {
        if (*len + dn[n].tlen + 1 > *cap) {
            int nc = *cap * 2 + dn[n].tlen + 64;
            char *nb = realloc(*b, nc);
            if (!nb) return;
            *b = nb;
            *cap = nc;
        }
        memcpy(*b + *len, dstr + dn[n].text, dn[n].tlen);
        *len += dn[n].tlen;
        return;
    }
    for (c = dn[n].first; c; c = dn[c].next) dom_text_walk(c, b, len, cap);
}
static char *dom_text_of(int n, int *plen)
{
    int len = 0, cap = 256;
    char *b = malloc(cap);
    if (!b) return 0;
    dom_text_walk(n, &b, &len, &cap);
    b[len] = 0;
    if (plen) *plen = len;
    return b;
}

/* ---- reading HTML ---- */
static unsigned dom_cs_dec(const char *b, int n, int *p, int cs)
{
    int save = cs_mode;
    unsigned u;
    cs_mode = cs;
    u = dec(b, n, p);
    cs_mode = save;
    return u;
}
/* b[*p] is '&' -> the character (or '&') */
static unsigned dom_entity(const char *b, int n, int *p)
{
    int q = *p + 1, i, k = 0;
    char name[12];
    if (q < n && b[q] == '#') {
        unsigned u = 0;
        q++;
        if (q < n && (b[q] == 'x' || b[q] == 'X')) { q++; while (q < n && hexval(b[q]) >= 0) u = u * 16 + hexval(b[q++]); }
        else while (q < n && b[q] >= '0' && b[q] <= '9') u = u * 10 + b[q++] - '0';
        if (q < n && b[q] == ';') q++;
        if (q == *p + 2) { (*p)++; return '&'; }
        *p = q;
        if (u >= 0x80 && u < 0xA0) u = cs_1252[u - 0x80];        /* (&#150; and the like: as windows-1252 means it) */
        return u ? u : 0xFFFD;
    }
    while (q < n && k < 10 && ((b[q] >= 'a' && b[q] <= 'z') || (b[q] >= 'A' && b[q] <= 'Z') || (k && b[q] >= '0' && b[q] <= '9')))
        name[k++] = b[q++];
    name[k] = 0;
    for (i = 0; entities[i].name; i++)
        if (!strcmp(entities[i].name, name)) {
            if (q < n && b[q] == ';') q++;
            *p = q;
            return entities[i].u;
        }
    if (k > 3 && q < n && b[q] == ';') {
        static const char *acc[] = { "acute", "grave", "circ", "uml", "tilde", "cedil", "ring", "caron", "slash", "ogon",
                                     "macr", "breve", "dot", 0 };
        for (i = 0; acc[i]; i++) if (!strcmp(name + 1, acc[i])) { *p = q + 1; return (unsigned char)name[0]; }
    }
    (*p)++;
    return '&';
}

/* text b[from..to) -> UTF-8 into a growing buffer, entities undone (or not) */
static char *dom_tb;
static int dom_tbn, dom_tbcap;
static void dom_tb_put(const char *s, int k)
{
    if (dom_tbn + k + 1 > dom_tbcap) {
        int nc = dom_tbcap ? dom_tbcap * 2 : 4096;
        char *nb;
        while (nc < dom_tbn + k + 1) nc *= 2;
        nb = realloc(dom_tb, nc);
        if (!nb) return;
        dom_tb = nb;
        dom_tbcap = nc;
    }
    memcpy(dom_tb + dom_tbn, s, k);
    dom_tbn += k;
}
static void dom_decode(const char *b, int from, int to, int cs, int ents)
{
    int p = from;
    dom_tbn = 0;
    while (p < to) {
        unsigned u;
        char o[4];
        if (ents && b[p] == '&') u = dom_entity(b, to, &p);
        else if ((unsigned char)b[p] < 0x80) u = (unsigned char)b[p++];
        else u = dom_cs_dec(b, to, &p, cs);
        if (u == '\r') continue;
        dom_tb_put(o, dom_utf8(u, o));
    }
}

static int dom_is_void(int t)
{
    switch (t) {
    case T_area: case T_base: case T_br: case T_col: case T_embed: case T_hr: case T_img: case T_input: case T_link:
    case T_meta: case T_param: case T_source: case T_track: case T_wbr: case T_keygen: case T_frame:
        return 1;
    }
    return 0;
}
/* a start tag that ends an open <p> */
static int dom_closes_p(int t)
{
    switch (t) {
    case T_address: case T_article: case T_aside: case T_blockquote: case T_center: case T_details: case T_dialog:
    case T_dir: case T_div: case T_dl: case T_fieldset: case T_figcaption: case T_figure: case T_footer: case T_form:
    case T_h1: case T_h2: case T_h3: case T_h4: case T_h5: case T_h6: case T_header: case T_hgroup: case T_hr:
    case T_main: case T_menu: case T_nav: case T_ol: case T_p: case T_pre: case T_section: case T_table: case T_ul:
    case T_search: case T_listing: case T_xmp: case T_plaintext: case T_summary:
        return 1;
    }
    return 0;
}

#define DOM_DEPTH 400
static int dstk[DOM_DEPTH], ndstk;
/* the nearest open t, not past a boundary; its place in dstk, or -1 */
static int dom_open_at(int t, const int *stops)
{
    int i, k;
    for (i = ndstk - 1; i >= 0; i--) {
        int g = dn[dstk[i]].tag;
        if (g == t) return i;
        for (k = 0; stops[k]; k++) if (g == stops[k]) return -1;
    }
    return -1;
}
static void dom_pop_to(int i) { if (i >= 0) ndstk = i; }   /* (dstk[i] and what's above it, closed) */

static void dom_attrs(int e, const char *b, int *pq, int end, int cs)
{
    int q = *pq;
    while (q < end && b[q] != '>') {
        int an, as = q, al, vs = 0, ve = 0, has = 0;
        if (is_space(b[q]) || b[q] == '/') { q++; continue; }
        while (q < end && !is_space(b[q]) && b[q] != '=' && b[q] != '>' && !(b[q] == '/' && b[q + 1] == '>')) q++;
        al = q - as;
        while (q < end && is_space(b[q])) q++;
        if (q < end && b[q] == '=') {
            has = 1;
            q++;
            while (q < end && is_space(b[q])) q++;
            if (q < end && (b[q] == '"' || b[q] == '\'')) {
                char qc = b[q++];
                vs = q;
                while (q < end && b[q] != qc) q++;
                ve = q;
                if (q < end) q++;
            } else {
                vs = q;
                while (q < end && !is_space(b[q]) && b[q] != '>') q++;
                ve = q;
            }
        }
        if (!al) { if (q < end && b[q] != '>') q++; continue; }
        an = atom_lc(b + as, al, 1);
        if (dom_attr_at(e, an) >= 0) continue;           /* (the first one counts) */
        if (has) { dom_decode(b, vs, ve, cs, 1); dom_set_attr_a(e, an, dom_tb ? dom_tb : "", dom_tbn); }
        else dom_set_attr_a(e, an, "", 0);
    }
    *pq = q;
}

/* the end of raw text: the next </name> (case not counted) */
static int dom_raw_end(const char *b, int p, int n, const char *name)
{
    int l = strlen(name);
    for (; p + 1 < n; p++)
        if (b[p] == '<' && b[p + 1] == '/') {
            int k;
            for (k = 0; k < l && p + 2 + k < n && lower(b[p + 2 + k]) == name[k]; k++) ;
            if (k == l && (p + 2 + l >= n || b[p + 2 + l] == '>' || is_space(b[p + 2 + l]))) return p;
        }
    return n;
}

/* HTML (n bytes, charset cs) -> nodes: a new document (parent 0), or
 * under parent (innerHTML) */
static void dom_parse(const char *b, int n, int cs, int parent)
{
    static const int scope[] = { T_html, T_table, T_td, T_th, T_caption, T_button, T_object, T_applet, T_marquee, T_template, 0 };
    static const int list_scope[] = { T_html, T_table, T_td, T_th, T_ul, T_ol, T_caption, T_template, 0 };
    static const int tbl_scope[] = { T_html, T_table, T_template, 0 };
    static const int row_scope[] = { T_html, T_table, T_tr, T_template, 0 };
    int p = 0, in_head = 0, cur;
    atoms_init();
    if (!parent) {
        dom_free();
        dom_doc = dom_new(DN_DOC, 0);
        dom_html = dom_elem(T_html, dom_doc);
        dom_head = dom_elem(T_head, dom_html);
        dom_body = dom_elem(T_body, dom_html);
        in_head = 1;
        ndstk = 0;
        dstk[ndstk++] = dom_html;
        cur = dom_head;
    } else {
        ndstk = 0;
        cur = parent;
    }
#define CUR (ndstk && !in_head && dstk[ndstk - 1] != dom_html ? dstk[ndstk - 1] : (in_head ? dom_head : (parent ? parent : dom_body)))
    while (p < n) {
        if (b[p] != '<') {                               /* text */
            int s = p, k, ws = 1;
            while (p < n && b[p] != '<') p++;
            for (k = s; k < p; k++) if (!is_space(b[k])) { ws = 0; break; }
            if (in_head) { if (ws) continue; in_head = 0; }
            dom_decode(b, s, p, cs, 1);
            if (dom_tbn) dom_text(dom_tb, dom_tbn, CUR);
            continue;
        }
        if (p + 3 < n && b[p + 1] == '!' && b[p + 2] == '-' && b[p + 3] == '-') {   /* a comment */
            int q = p + 4;
            while (q + 2 < n && !(b[q] == '-' && b[q + 1] == '-' && b[q + 2] == '>')) q++;
            p = q + 3;
            continue;
        }
        if (b[p + 1] == '!' || b[p + 1] == '?') {        /* <!DOCTYPE>, <?xml?> */
            while (p < n && b[p] != '>') p++;
            p++;
            continue;
        }
        if (b[p + 1] == '/') {                           /* an end tag */
            int q = p + 2, s = q, t, i;
            while (q < n && !is_space(b[q]) && b[q] != '>') q++;
            t = atom_lc(b + s, q - s, 0);
            while (q < n && b[q] != '>') q++;
            p = q + 1;
            if (!t || t == T_body || t == T_html || t == T_head) { if (t == T_head) in_head = 0; continue; }
            if (t == T_p && dom_open_at(T_p, scope) < 0) continue;
            for (i = ndstk - 1; i >= 0; i--) {           /* the nearest open one, closed (and all in it) */
                if (dn[dstk[i]].tag == t) { dom_pop_to(i); break; }
                if (dstk[i] == dom_html || (parent && i == 0 && dstk[0] == parent)) break;
                if ((dn[dstk[i]].tag == T_table && t != T_table) || dn[dstk[i]].tag == T_template) break;
            }
            continue;
        }
        if (!((b[p + 1] >= 'a' && b[p + 1] <= 'z') || (b[p + 1] >= 'A' && b[p + 1] <= 'Z'))) {   /* "<" as text */
            if (in_head) in_head = 0;
            dom_text("<", 1, CUR);
            p++;
            continue;
        }
        {                                                /* a start tag */
            int q = p + 1, s = q, t, e, self, i;
            while (q < n && !is_space(b[q]) && b[q] != '>' && b[q] != '/') q++;
            t = atom_lc(b + s, q - s, 1);
            if (t == T_html || t == T_body || (t == T_head && !parent)) {            /* (its attributes: to ours) */
                int e2 = parent ? 0 : t == T_html ? dom_html : t == T_head ? dom_head : dom_body;
                if (e2) dom_attrs(e2, b, &q, n, cs);
                while (q < n && b[q] != '>') q++;
                p = q + 1;
                if (t == T_body) in_head = 0;
                continue;
            }
            if (in_head && t != T_title && t != T_meta && t != T_link && t != T_style && t != T_script && t != T_base &&
                t != T_noscript && t != T_template) in_head = 0;
            /* the end tags a page may leave out */
            if (dom_closes_p(t)) dom_pop_to(dom_open_at(T_p, scope));
            if (t == T_li) dom_pop_to(dom_open_at(T_li, list_scope));
            if (t == T_dt || t == T_dd) {
                int a1 = dom_open_at(T_dt, list_scope), a2 = dom_open_at(T_dd, list_scope);
                dom_pop_to(a1 > a2 ? a1 : a2);
            }
            if (t == T_option || t == T_optgroup) {
                if (ndstk && dn[dstk[ndstk - 1]].tag == T_option) ndstk--;
                if (t == T_optgroup && ndstk && dn[dstk[ndstk - 1]].tag == T_optgroup) ndstk--;
            }
            if (t == T_tr) {
                int a1 = dom_open_at(T_tr, tbl_scope);
                dom_pop_to(a1);
                if (a1 < 0) { int a2 = dom_open_at(T_td, tbl_scope), a3 = dom_open_at(T_th, tbl_scope); dom_pop_to(a2 > a3 ? a2 : a3); }
            }
            if (t == T_td || t == T_th) {
                int a1 = dom_open_at(T_td, row_scope), a2 = dom_open_at(T_th, row_scope);
                dom_pop_to(a1 > a2 ? a1 : a2);
            }
            if (t == T_thead || t == T_tbody || t == T_tfoot) {
                int k, best = -1;
                static const int sec[] = { T_tr, T_td, T_th, T_thead, T_tbody, T_tfoot, 0 };
                for (k = 0; sec[k]; k++) { int a1 = dom_open_at(sec[k], tbl_scope); if (a1 >= 0 && (best < 0 || a1 < best)) best = a1; }
                dom_pop_to(best);
            }
            if (t == T_a) dom_pop_to(dom_open_at(T_a, scope));
            if (t == T_button) dom_pop_to(dom_open_at(T_button, scope));
            if (t >= T_h1 && t <= T_h6 && ndstk && dn[dstk[ndstk - 1]].tag >= T_h1 && dn[dstk[ndstk - 1]].tag <= T_h6) ndstk--;
            if (t == T_form && dom_open_at(T_form, tbl_scope) >= 0) { while (q < n && b[q] != '>') q++; p = q + 1; continue; }
            e = dom_elem(t, CUR);
            if (!e) return;
            dom_attrs(e, b, &q, n, cs);
            self = q > 0 && q <= n && b[q - 1] == '/';
            p = q < n ? q + 1 : n;
            if (t == T_script || t == T_style || t == T_textarea || t == T_title || t == T_xmp || t == T_noframes ||
                t == T_iframe) {
                int en = dom_raw_end(b, p, n, atom_name(t));
                dom_decode(b, p, en, cs, t == T_textarea || t == T_title);
                if (dom_tbn) dom_text(dom_tb, dom_tbn, e);
                while (en < n && b[en] != '>') en++;
                p = en < n ? en + 1 : n;
                continue;
            }
            if (t == T_svg && !self) {                   /* kept whole */
                int depth = 1, r = p, st;
                while (r < n && depth) {
                    if (b[r] == '<' && r + 4 < n && lower(b[r + 1]) == 's' && lower(b[r + 2]) == 'v' && lower(b[r + 3]) == 'g' &&
                        (b[r + 4] == '>' || is_space(b[r + 4]))) depth++;
                    else if (b[r] == '<' && b[r + 1] == '/' && r + 5 < n && lower(b[r + 2]) == 's' && lower(b[r + 3]) == 'v' &&
                             lower(b[r + 4]) == 'g') { if (!--depth) break; }
                    r++;
                }
                while (r < n && b[r] != '>') r++;
                if (r < n) r++;
                st = s - 1;
                dn[e].flags |= DF_SVG;
                dn[e].text = dom_str(b + st, r - st);
                dn[e].tlen = r - st;
                p = r;
                continue;
            }
            if (t == T_math) { p = dom_raw_end(b, p, n, "math"); while (p < n && b[p] != '>') p++; p++; continue; }
            if (t == T_template) dn[e].flags |= DF_TPL;
            if (self || dom_is_void(t)) continue;
            if (ndstk < DOM_DEPTH) dstk[ndstk++] = e;
        }
    }
#undef CUR
}

/* ---- writing HTML (innerHTML / outerHTML) ---- */
static void dom_esc(const char *s, int n, int attr)
{
    int i;
    for (i = 0; i < n; i++) {
        char c = s[i];
        if (c == '&') dom_tb_put("&amp;", 5);
        else if (c == '<' && !attr) dom_tb_put("&lt;", 4);
        else if (c == '>' && !attr) dom_tb_put("&gt;", 4);
        else if (c == '"' && attr) dom_tb_put("&quot;", 6);
        else dom_tb_put(&c, 1);
    }
}
static void dom_ser(int n, int outer)
{
    int c, i;
    if (dn[n].type == DN_TEXT) {
        int raw = dn[n].parent && (dn[dn[n].parent].tag == T_script || dn[dn[n].parent].tag == T_style);
        if (raw) dom_tb_put(dstr + dn[n].text, dn[n].tlen); else dom_esc(dstr + dn[n].text, dn[n].tlen, 0);
        return;
    }
    if (dn[n].type == DN_COMMENT) { dom_tb_put("<!--", 4); dom_tb_put(dstr + dn[n].text, dn[n].tlen); dom_tb_put("-->", 3); return; }
    if (dn[n].type != DN_ELEM) { for (c = dn[n].first; c; c = dn[c].next) dom_ser(c, 1); return; }
    if (outer && (dn[n].flags & DF_SVG)) { dom_tb_put(dstr + dn[n].text, dn[n].tlen); return; }
    if (outer) {
        const char *nm = atom_name(dn[n].tag);
        dom_tb_put("<", 1);
        dom_tb_put(nm, strlen(nm));
        for (i = 0; i < dn[n].nattr; i++) {
            const char *an = atom_name(da[dn[n].attr + i].name), *av = dstr + da[dn[n].attr + i].val;
            dom_tb_put(" ", 1);
            dom_tb_put(an, strlen(an));
            dom_tb_put("=\"", 2);
            dom_esc(av, strlen(av), 1);
            dom_tb_put("\"", 1);
        }
        dom_tb_put(">", 1);
        if (dom_is_void(dn[n].tag)) return;
    }
    for (c = dn[n].first; c; c = dn[c].next) dom_ser(c, 1);
    if (outer) {
        const char *nm = atom_name(dn[n].tag);
        dom_tb_put("</", 2);
        dom_tb_put(nm, strlen(nm));
        dom_tb_put(">", 1);
    }
}
/* -> malloc'd UTF-8 */
static char *dom_html_of(int n, int outer)
{
    char *r;
    dom_tbn = 0;
    dom_ser(n, outer);
    r = malloc(dom_tbn + 1);
    if (r) { memcpy(r, dom_tb ? dom_tb : "", dom_tbn); r[dom_tbn] = 0; }
    return r;
}

/* ---- finding ---- */
static int dom_next_in(int n, int root)                  /* the next node in document order, within root */
{
    if (dn[n].first && !(dn[n].flags & DF_TPL)) return dn[n].first;
    while (n && n != root) {
        if (dn[n].next) return dn[n].next;
        n = dn[n].parent;
    }
    return 0;
}
static int dom_by_id(const char *id)
{
    int n, a = atom_get("id", 2, 0);
    if (!a || !dom_doc) return 0;
    for (n = dom_doc; n; n = dom_next_in(n, dom_doc))
        if (dn[n].type == DN_ELEM) {
            const char *v = dom_attr_a(n, a);
            if (v && !strcmp(v, id)) return n;
        }
    return 0;
}
static int dom_has_class(int e, const char *c)
{
    const char *l = dom_attr(e, "class");
    int n = strlen(c);
    if (!l || !n) return 0;
    while (*l) {
        while (*l == ' ' || *l == '\t' || *l == '\n') l++;
        if (!memcmp(l, c, n) && (!l[n] || l[n] == ' ' || l[n] == '\t' || l[n] == '\n')) return 1;
        while (*l && *l != ' ' && *l != '\t' && *l != '\n') l++;
    }
    return 0;
}
/* is a inside b (or b itself)? */
static int dom_within(int a, int b)
{
    while (a) { if (a == b) return 1; a = dn[a].parent; }
    return 0;
}

#endif
