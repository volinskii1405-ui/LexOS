/* layout.h - LexOS Web's layout: dom.h's tree, styled by css.h, made
 * into browser.c's items (text, boxes, rules, pictures, form fields)
 * at their places on the page.
 *
 * Blocks stack, with their margins (collapsed, roughly), borders,
 * padding, backgrounds (a color, or a picture - covering the box) and
 * widths (auto, px, %, min-/max-, margin: auto centering); inline text
 * flows into lines (text-align, white-space, text-transform, links);
 * inline-blocks, pictures and fields sit on the lines; floats go to a
 * side with the lines around them; position: relative moves a box,
 * absolute and fixed put it on top (on the box it's positioned in, or
 * the page); flex lays out rows (wrapping, grow/shrink, justify-
 * content, align-items, gap, order) and columns; grid its columns
 * (px, %, fr, auto, minmax(), repeat(), auto-fill/auto-fit, areas,
 * spans); tables their columns as wide as their cells need. Boxes
 * with overflow: hidden cut what's outside them off.
 *
 * Included by browser.c (its items, fonts, links, images, fields). */
#ifndef LAYOUT_H
#define LAYOUT_H

#define CS(e) ((struct cstyle *)dn[e].cs)
static int lay_depth;
static int lay_dummy_out;
static int lay_fixed_w;                                   /* (the next lay_block: its width is al..ar, already worked out) */
static void lay_block(int e, int al, int ar, int shrink);
static void lay_flow(int e);
static void lay_node_inline(int c);

/* ---- floats: the boxes the lines go around (this formatting context's) ---- */
#define FL_MAX 256
static struct { int x0, x1, y0, y1, side; } fl[FL_MAX];
static int nfl, fl_base;
/* the line at yy (h high) between l and r: narrowed by the floats */
static void fl_bounds(int yy, int h, int l, int r, int *pl, int *pr)
{
    int i;
    for (i = fl_base; i < nfl; i++) {
        if (fl[i].y1 <= yy || fl[i].y0 >= yy + h) continue;
        if (fl[i].side == F_LEFT) { if (fl[i].x1 > l && fl[i].x0 < r) l = fl[i].x1; }
        else if (fl[i].x0 < r && fl[i].x1 > l) r = fl[i].x0;
    }
    *pl = l;
    *pr = r < l + 8 ? l + 8 : r;
}
static int fl_bottom(int side)                            /* how far down this context's floats go */
{
    int i, b = 0;
    for (i = fl_base; i < nfl; i++) if ((!side || fl[i].side == side || side == 3) && fl[i].y1 > b) b = fl[i].y1;
    return b;
}
/* the next line: its room, past the floats */
static void line_room(void)
{
    int l, r;
    fl_bounds(y, 16, cb_l, cb_r, &l, &r);
    line_left = l;
    line_right = r;
    if (line_start == nitems || x < line_left) x = line_left;
}

/* ---- a box's edges ---- */
static int lay_len(const struct clen *l, int ref)
{
    if (l->kind != L_LEN) return 0;
    return css_resolve(l, ref);
}
static int lay_bw(struct cstyle *cs, int i) { return cs->bw[i] > 0 && cs->bc[i] != 0xFFFFFFFFu ? cs->bw[i] : 0; }
static int lay_hpad(struct cstyle *cs, int ref)          /* padding + border, left and right */
{
    return lay_len(&cs->p[1], ref) + lay_len(&cs->p[3], ref) + lay_bw(cs, 1) + lay_bw(cs, 3);
}
static int lay_scale(struct cstyle *cs) { return cs->fsize >= 24 ? 2 : 1; }
static int lay_is_block(struct cstyle *cs)
{
    switch (cs->display) {
    case D_BLOCK: case D_FLEX: case D_GRID: case D_LIST_ITEM: case D_TABLE: case D_ROW: case D_ROW_GROUP: case D_CAPTION:
    case D_CELL: case D_COLUMN:
        return 1;
    }
    return 0;
}
static int lay_replaced(int e)
{
    switch (dn[e].tag) {
    case T_img: case T_svg: case T_input: case T_select: case T_textarea: case T_button: case T_video: case T_iframe:
    case T_canvas: case T_object: case T_embed: case T_audio: case T_progress: case T_meter:
        return 1;
    }
    return 0;
}
/* hidden for good: sr-only boxes and such */
static int lay_hidden(int e, struct cstyle *cs)
{
    static const char *hid[] = { "sr-only", "visually-hidden", "visuallyhidden", "screen-reader-text", "screenreader",
        "d-none", "is-hidden", "u-hidden", "a11y-hidden", "sr-text", "skip-link", "hidden-xs", "hidden-sm", "show-for-sr", 0 };
    int i;
    if (!cs || cs->display == D_NONE) return 1;
    if ((cs->position == P_ABSOLUTE || cs->position == P_FIXED) &&
        ((cs->w.kind == L_LEN && !cs->w.pct && cs->w.px <= 1.5f) || (cs->h.kind == L_LEN && !cs->h.pct && cs->h.px <= 1.5f) ||
         (cs->sronly & 2) || (cs->pos[3].kind == L_LEN && cs->pos[3].px < -900) || (cs->pos[0].kind == L_LEN && cs->pos[0].px < -900)))
        return 1;
    if (cs->sronly & 4) return 1;
    if (cs->tindent.kind == L_LEN && cs->tindent.px < -900) return 1;
    if (dn[e].tag == T_input) { const char *t = dom_attr(e, "type"); if (t && starts_ci(t, "hidden")) return 0; }
    for (i = 0; hid[i]; i++) if (dom_has_class(e, hid[i])) return 1;
    {
        const char *ah = dom_attr(e, "aria-hidden");
        if (ah && !strcmp(ah, "true") && dn[e].tag != T_svg && dn[e].tag != T_img && !dn[e].first) return 1;
    }
    return 0;
}

/* ================================================================
 * pictures: read once a page (by address), shown at any size
 * ================================================================ */
#define IMGC_MAX 96
static struct imgc { char *url; unsigned short *pix; int w, h, bad; unsigned bg; } imgc[IMGC_MAX];
static int nimgc;
static void imgc_free(void)
{
    int i;
    for (i = 0; i < nimgc; i++) { free(imgc[i].url); free(imgc[i].pix); }
    nimgc = 0;
}
/* a data: URI's bytes (base64 or %-encoded) -> malloc'd */
static unsigned char *img_data_uri(const char *u, int *n)
{
    const char *c = u + 5, *d;
    int b64 = 0, k = 0, bits = 0, acc = 0;
    unsigned char *o;
    while (*c && *c != ',') { if (starts_ci(c, ";base64")) b64 = 1; c++; }
    if (!*c) return 0;
    d = c + 1;
    o = malloc(strlen(d) + 1);
    if (!o) return 0;
    for (; *d; d++) {
        int v;
        if (b64) {
            int ch = *d;
            v = ch >= 'A' && ch <= 'Z' ? ch - 'A' : ch >= 'a' && ch <= 'z' ? ch - 'a' + 26 : ch >= '0' && ch <= '9' ? ch - '0' + 52 :
                ch == '+' || ch == '-' ? 62 : ch == '/' || ch == '_' ? 63 : -1;
            if (v < 0) continue;
            acc = acc << 6 | v;
            bits += 6;
            if (bits >= 8) { bits -= 8; o[k++] = acc >> bits & 255; }
        } else if (*d == '%' && hexval(d[1]) >= 0 && hexval(d[2]) >= 0) { o[k++] = hexval(d[1]) * 16 + hexval(d[2]); d += 2; }
        else o[k++] = *d;
    }
    *n = k;
    return o;
}
static unsigned lay_img_bg = 0xFFFFFF;
static int img_get_bg(const char *src, int want_w, int want_h, unsigned bgc);
/* the picture at url (resolved): its cache entry, or -1 */
static int img_get(const char *src, int want_w, int want_h)
{
    return img_get_bg(src, want_w, want_h, lay_img_bg);
}
static int img_get_bg(const char *src, int want_w, int want_h, unsigned bgc)
{
    char where[URL_MAX];
    int i, n = 0, w = 0, h = 0;
    unsigned char *buf = 0;
    unsigned *pix = 0;
    if (starts_ci(src, "data:")) { copy(where, src, 64); where[63] = 0; }
    else resolve(base_url[0] ? base_url : url, src, where);
    for (i = 0; i < nimgc; i++)
        if (!strcmp(imgc[i].url, starts_ci(src, "data:") ? src : where) && (imgc[i].bg == bgc || imgc[i].bg == 0xFFFFFFFFu))
            return imgc[i].bad ? -1 : i;
    if (nimgc >= IMGC_MAX) return -1;
    i = nimgc++;
    memset(&imgc[i], 0, sizeof imgc[i]);
    imgc[i].url = dup_str(starts_ci(src, "data:") ? src : where);
    imgc[i].bad = 1;
    imgc[i].bg = bgc;
    if (!imgc[i].url) return -1;
    if (starts_ci(src, "data:")) buf = img_data_uri(src, &n);
    else {
        copy(status, "Loading pictures... ", sizeof status);
        {
            char t[8];
            int k = 0, v = nimgc;
            do { t[k++] = '0' + v % 10; v /= 10; } while (v);
            while (k) { char c[2] = { t[--k], 0 }; append(status, c, sizeof status); }
        }
        draw_status();
        gfx_blit_rect(frame, 0, H - STATUS, W, STATUS);
        n = load_cached(where, &buf);
    }
    if (n > 8 && buf) {
        int mw = 786, mh = 2400;
        if (buf[0] == 137 && buf[1] == 'P') { png_bg = bgc; pix = load_png(buf, n, &w, &h); png_bg = 0xFFFFFF; }
        else if (buf[0] == 0xFF && buf[1] == 0xD8) { pix = jpeg_load(buf, n, mw, mh, &w, &h); imgc[i].bg = 0xFFFFFFFFu; }
        else if (!memcmp(buf, "GIF8", 4)) pix = gif_load(buf, n, mw, mh, bgc, &w, &h);
        else if (!memcmp(buf, "RIFF", 4) && n > 12 && !memcmp(buf + 8, "WEBP", 4)) pix = webp_load(buf, n, mw, mh, bgc, &w, &h);
        else if (buf[0] == 'B' && buf[1] == 'M') pix = load_bmp(buf, n, &w, &h);
        else {                                            /* SVG? (text: <svg or <?xml) */
            int k = 0;
            while (k < n && k < 512 && buf[k] != '<') k++;
            if (k < n && (starts_ci((char *)buf + k, "<svg") || starts_ci((char *)buf + k, "<?xml") || starts_ci((char *)buf + k, "<!--") ||
                          starts_ci((char *)buf + k, "<!DOCTYPE svg")))
                pix = svg_render((char *)buf, n, want_w > 0 ? want_w : 0, want_h > 0 ? want_h : 0, bgc, text_col, &w, &h);
        }
    }
    free(buf);
    if (!pix) { pi.imgs_bad++; return -1; }
    if (w > 786) {                                       /* (wider than the page: smaller) */
        int nw = 786, nh = h * 786 / w, r, c;
        unsigned *s2 = malloc(nw * nh * 4);
        if (s2) {
            for (r = 0; r < nh; r++) for (c = 0; c < nw; c++) s2[r * nw + c] = pix[(r * h / nh) * w + c * w / nw];
            free(pix);
            pix = s2; w = nw; h = nh;
        }
    }
    to16(pix, w * h);
    imgc[i].pix = (unsigned short *)pix;
    imgc[i].w = w;
    imgc[i].h = h;
    imgc[i].bad = 0;
    pi.imgs++;
    return i;
}
/* a picture item, w x h, from the cache (scaled; cover: cut to fill) */
static struct item *img_item(int ci, int ix, int iy, int w, int h, int cover)
{
    struct item *it;
    unsigned short *p;
    int r, c, sw = imgc[ci].w, sh = imgc[ci].h, ox = 0, oy = 0, vw = sw, vh = sh;
    if (w < 1 || h < 1 || w > 4096 || h > 8192) return 0;
    if (cover && sw && sh) {                             /* the middle of it, as the box's shape */
        if ((long long)sw * h > (long long)sh * w) { vw = sh * w / h; ox = (sw - vw) / 2; }
        else { vh = sw * h / w; oy = (sh - vh) / 2; }
        if (vw < 1) vw = 1;
        if (vh < 1) vh = 1;
    }
    if (w == sw && h == sh) p = imgc[ci].pix;
    else {
        p = malloc(w * h * 2);
        if (!p) return 0;
        for (r = 0; r < h; r++) {
            const unsigned short *row = imgc[ci].pix + (oy + r * vh / h) * sw + ox;
            for (c = 0; c < w; c++) p[r * w + c] = row[c * vw / w];
        }
    }
    if (!(it = new_item(IT_IMAGE))) { if (p != imgc[ci].pix) free(p); return 0; }
    it->x = ix; it->y = iy; it->w = w; it->h = h;
    it->pix = (unsigned *)p;
    it->own = p != imgc[ci].pix;
    it->link = cur_link;
    return it;
}

/* ================================================================
 * form fields: one ctrl per <input>/<textarea>/<select>/<button>
 * element, kept while the page is (what's typed survives a new layout)
 * ================================================================ */
static void ctrl_text_u8(struct ctrl *c, const char *t)
{
    int p = 0, r = 0, v = 0, n = strlen(t);
    free(c->raw); free(c->val);
    c->raw = malloc(VAL_MAX); c->val = malloc(VAL_MAX);
    if (!c->raw || !c->val) { free(c->raw); free(c->val); c->raw = c->val = 0; return; }
    while (p < n) {
        unsigned u = dom_u8(t, n, &p);
        char o[4], f[3];
        int k = uni_cs(u, cs_mode, o), m = to_font(u, f), i;
        if (u == '\r') continue;
        if (r + k < VAL_MAX - 1) for (i = 0; i < k; i++) c->raw[r++] = o[i];
        if (u == '\n' || u == '\t') { f[0] = u == '\n' ? '\n' : ' '; m = 1; }
        if (v + m < VAL_MAX - 1) for (i = 0; i < m; i++) c->val[v++] = f[i];
    }
    c->raw[r] = 0; c->val[v] = 0;
}
static void font_text(const char *t, char *out, int max)  /* UTF-8 -> the font's bytes */
{
    int p = 0, k = 0, n = strlen(t);
    while (p < n && k < max - 1) {
        char f[3];
        int m = to_font(dom_u8(t, n, &p), f), i;
        for (i = 0; i < m && k < max - 1; i++) out[k++] = f[i] == '\n' || f[i] == '\t' || f[i] == '\r' ? ' ' : f[i];
    }
    out[k] = 0;
}
static int form_of(int e)
{
    int f = 0, i;
    const char *fa = dom_attr(e, "form");
    if (fa && *fa) { f = dom_by_id(fa); if (f && dn[f].tag != T_form) f = 0; }
    if (!f) for (f = dn[e].parent; f && dn[f].tag != T_form; f = dn[f].parent) ;
    if (!f) return -1;
    for (i = 0; i < nforms; i++) if (forms[i].node == f) return i;
    if (nforms >= FORMS_MAX) return -1;
    {
        const char *a = dom_attr(f, "action"), *m = dom_attr(f, "method");
        forms[nforms].node = f;
        copy(forms[nforms].action, a ? a : "", URL_MAX);
        forms[nforms].post = m && starts_ci(m, "post");
    }
    return nforms++;
}
static int ctrl_kind_of(int e)
{
    const char *t;
    if (dn[e].tag == T_textarea) return CT_AREA;
    if (dn[e].tag == T_select) return CT_SELECT;
    if (dn[e].tag == T_button) { t = dom_attr(e, "type"); return t && (starts_ci(t, "button") || starts_ci(t, "reset")) ? CT_BUTTON : CT_SUBMIT; }
    t = dom_attr(e, "type");
    if (!t || !*t) return CT_TEXT;
    if (starts_ci(t, "password")) return CT_PASS;
    if (starts_ci(t, "hidden")) return CT_HIDDEN;
    if (starts_ci(t, "checkbox")) return CT_CHECK;
    if (starts_ci(t, "radio")) return CT_RADIO;
    if (starts_ci(t, "submit")) return CT_SUBMIT;
    if (starts_ci(t, "image")) return CT_IMAGE;
    if (starts_ci(t, "button") || starts_ci(t, "reset")) return CT_BUTTON;
    if (starts_ci(t, "file")) return CT_BUTTON;
    return CT_TEXT;
}
/* the options of a <select> -> "text\0value\0" each */
static void ctrl_options(struct ctrl *c, int e)
{
    int o, ol = 0, cap = 4096, wmax = 4;
    char *opts = malloc(cap);
    c->nopt = 0;
    c->sel = 0;
    if (!opts) return;
    for (o = dn[e].first; o; o = dom_next_in(o, e)) {
        char shown[128], *txt;
        const char *v;
        int k, vl;
        if (dn[o].tag != T_option) continue;
        txt = dom_text_of(o, 0);
        if (!txt) continue;
        font_text(txt, shown, sizeof shown);
        {                                                /* (spaces at its ends: off) */
            int s0 = 0, e0 = strlen(shown);
            while (shown[s0] == ' ') s0++;
            while (e0 > s0 && shown[e0 - 1] == ' ') e0--;
            memmove(shown, shown + s0, e0 - s0);
            shown[e0 - s0] = 0;
        }
        v = dom_attr(o, "value");
        if (!v) v = txt;
        k = strlen(shown);
        vl = strlen(v);
        if (ol + k + vl * 3 + 8 > cap) {
            char *no;
            cap = (ol + k + vl * 3 + 8) * 2;
            no = realloc(opts, cap);
            if (!no) { free(txt); break; }
            opts = no;
        }
        memcpy(opts + ol, shown, k + 1);
        ol += k + 1;
        {                                                /* the value, in the page's charset */
            int p = 0;
            while (p < vl) { unsigned u = dom_u8(v, vl, &p); ol += uni_cs(u, cs_mode, opts + ol); }
            opts[ol++] = 0;
        }
        if (k > wmax) wmax = k;
        if (dom_attr(o, "selected")) c->sel = c->nopt;
        c->nopt++;
        free(txt);
    }
    free(c->opts);
    c->opts = opts;
    c->rows = wmax > 40 ? 40 : wmax;                     /* (its width, in letters) */
}
/* a <button>'s words: what's in it (and its value, the page's) */
static void ctrl_btn_label(struct ctrl *c, int e)
{
    char *t = dom_text_of(e, 0), lab[64];
    const char *v = dom_attr(e, "value");
    ctrl_text_u8(c, v ? v : "");
    font_text(t ? t : "", lab, sizeof lab);
    free(t);
    {                                                    /* (its words, spaces joined) */
        int i, k2 = 0;
        for (i = 0; lab[i]; i++) if (lab[i] != ' ' || (k2 && lab[k2 - 1] != ' ')) lab[k2++] = lab[i];
        while (k2 && lab[k2 - 1] == ' ') k2--;
        lab[k2] = 0;
    }
    if (!lab[0]) {
        const char *al = dom_attr(e, "aria-label");
        if (!al) al = dom_attr(e, "title");
        font_text(al ? al : "", lab, sizeof lab);
    }
    free(c->val);
    c->val = malloc(strlen(lab) + 2);
    if (c->val) copy(c->val, lab, strlen(lab) + 1);
}
static int ctrl_for(int e)
{
    struct ctrl *c;
    int k;
    if (dn[e].ctrl >= 0 && dn[e].ctrl < nctrls && ctrls[dn[e].ctrl].node == e) return dn[e].ctrl;
    if (nctrls >= CTRL_MAX) return -1;
    k = nctrls++;
    c = &ctrls[k];
    memset(c, 0, sizeof *c);
    c->node = e;
    c->item = -1;
    c->kind = ctrl_kind_of(e);
    c->form = form_of(e);
    dn[e].ctrl = k;
    {
        const char *nm = dom_attr(e, "name");
        if (nm) copy(c->name, nm, sizeof c->name);
    }
    if (c->kind == CT_SELECT) ctrl_options(c, e);
    else if (c->kind == CT_AREA) {
        char *t = dom_text_of(e, 0);
        const char *s = t ? t : "";
        if (*s == '\n') s++;
        ctrl_text_u8(c, s);
        free(t);
        c->rows = 3;
    } else if (dn[e].tag == T_button) {
        ctrl_btn_label(c, e);
    } else {
        const char *v = dom_attr(e, "value");
        if (!v && (c->kind == CT_SUBMIT || c->kind == CT_IMAGE)) v = dom_attr(e, "alt");
        if ((!v || !*v) && (c->kind == CT_SUBMIT || c->kind == CT_IMAGE)) v = "Submit";
        if ((!v || !*v) && c->kind == CT_BUTTON) {
            const char *t = dom_attr(e, "type");
            v = t && starts_ci(t, "file") ? "Choose a file" : t && starts_ci(t, "reset") ? "Reset" : "...";
        }
        ctrl_text_u8(c, v ? v : "");
        if (dom_attr(e, "checked")) c->checked = 1;
    }
    {
        const char *ph = dom_attr(e, "placeholder");
        if (!ph) ph = dom_attr(e, "aria-label");
        if (ph && c->kind != CT_SUBMIT && c->kind != CT_BUTTON) font_text(ph, c->ph, sizeof c->ph);
    }
    return k;
}

/* ================================================================
 * widths a box needs: at least (its longest word), at most (all on one line)
 * ================================================================ */
static int mgen;
static void measure(int e, int *pmin, int *pmax);
static int text_cols(const char *s, int n, int *word, int ws)
{
    int p = 0, cols = 0, w = 0, mw = 0, sp = 1, line = 0, mline = 0;
    while (p < n) {
        unsigned u = dom_u8(s, n, &p);
        if (u == '\n' && (ws == WS_PRE || ws == WS_PRE_WRAP || ws == WS_PRE_LINE)) {
            if (line > mline) mline = line;
            line = 0; w = 0; continue;
        }
        if (u == ' ' || u == '\t' || u == '\n' || u == '\r') {
            if (w > mw) mw = w;
            w = 0;
            if (!sp || ws == WS_PRE || ws == WS_PRE_WRAP) { cols++; line++; }
            sp = 1;
            continue;
        }
        sp = 0;
        if (u >= 0x300 && u < 0x370) continue;
        cols++; line++; w++;
    }
    if (w > mw) mw = w;
    if (line > mline) mline = line;
    if (ws == WS_NOWRAP || ws == WS_PRE) mw = ws == WS_PRE ? mline : cols;
    *word = mw;
    return ws == WS_PRE || ws == WS_PRE_WRAP || ws == WS_PRE_LINE ? mline : cols;
}
static void replaced_size(int e, struct cstyle *cs, int avail, int *pw, int *ph);
/* e's content (its children): min and max */
static void measure_kids(int e, struct cstyle *cs, int *pmin, int *pmax)
{
    int c, mn = 0, mx = 0, run_mn = 0, run_mx = 0, sc = lay_scale(cs);
    int flexrow = (cs->display == D_FLEX || cs->display == D_INLINE_FLEX) && (cs->fdir == FD_ROW || cs->fdir == FD_ROW_REV);
    int gap = flexrow ? lay_len(&cs->cgap, 0) : 0, nk = 0;
    for (c = dn[e].first; c; c = dn[c].next) {
        int a, b;
        if (dn[c].type == DN_TEXT) {
            int word, cols = text_cols(dstr + dn[c].text, dn[c].tlen, &word, cs->ws);
            a = word * 8 * sc;
            b = cols * 8 * sc;
            if (flexrow) { if (!cols) continue; mn = cs->fwrap ? (a > mn ? a : mn) : mn + a; mx += b; nk++; continue; }
            if (a > run_mn) run_mn = a;
            run_mx += b;
            continue;
        }
        if (dn[c].type != DN_ELEM || !CS(c) || lay_hidden(c, CS(c))) continue;
        if (CS(c)->position == P_ABSOLUTE || CS(c)->position == P_FIXED) continue;
        if (dn[c].tag == T_br) { if (run_mx > mx) mx = run_mx; run_mx = 0; continue; }
        measure(c, &a, &b);
        {
            struct cstyle *k = CS(c);
            int m = lay_len(&k->m[1], 0) + lay_len(&k->m[3], 0);
            a += m; b += m;
        }
        if (flexrow) { mn = cs->fwrap ? (a > mn ? a : mn) : mn + a; mx += b; nk++; continue; }
        if (lay_is_block(CS(c)) && CS(c)->flt == F_NONE) {
            if (run_mn > mn) mn = run_mn;
            if (run_mx > mx) mx = run_mx;
            run_mn = run_mx = 0;
            if (a > mn) mn = a;
            if (b > mx) mx = b;
        } else {
            if (a > run_mn) run_mn = a;
            run_mx += b;
        }
    }
    if (flexrow && nk > 1) { mx += gap * (nk - 1); if (!cs->fwrap) mn += gap * (nk - 1); }
    if (run_mn > mn) mn = run_mn;
    if (run_mx > mx) mx = run_mx;
    if (cs->display == D_GRID || cs->display == D_INLINE_GRID) {          /* a grid: its columns side by side */
        const char *t = cs->grid_cols ? css_pool + cs->grid_cols : 0;
        if (t) {
            int cols = 0, fixed = 0;
            const char *p = t;
            while (*p) {
                struct clen l;
                char tok[64];
                int k = 0;
                while (*p == ' ') p++;
                if (starts_ci(p, "repeat(")) { cols += 2; while (*p && *p != ')') p++; if (*p) p++; continue; }
                while (*p && *p != ' ' && k < 63) tok[k++] = *p++;
                tok[k] = 0;
                if (!k) break;
                if (tok[0] == '[') continue;
                cols++;
                if (css_len(tok, &l) && l.kind == L_LEN && !l.pct && !strstr_ci(tok, "fr")) fixed += (int)l.px;
            }
            if (cols > 1) { mx = mx * cols; if (fixed > mn) mn = fixed; }
        }
    }
    *pmin = mn;
    *pmax = mx;
}
static void measure(int e, int *pmin, int *pmax)
{
    struct cstyle *cs = CS(e);
    int mn, mx, pad;
    if (!cs || lay_hidden(e, cs)) { *pmin = *pmax = 0; return; }
    if (dn[e].mgen == mgen) { *pmin = dn[e].minw; *pmax = dn[e].maxw; return; }
    pad = lay_hpad(cs, 0);
    if (lay_replaced(e)) {
        int w, h;
        replaced_size(e, cs, 760, &w, &h);
        mn = mx = w + pad;
        if (cs->w.kind == L_LEN && cs->w.pct && !cs->w.px) mn = pad + 16;
    } else if (cs->w.kind == L_LEN && !cs->w.pct) {
        mn = mx = (int)cs->w.px + (cs->boxsz ? 0 : pad);
    } else if (dn[e].tag == T_table || cs->display == D_TABLE || cs->display == D_ROW || cs->display == D_ROW_GROUP) {
        int r, a, b;
        mn = mx = 0;
        if (cs->display == D_ROW) {                      /* a row: its cells side by side */
            for (r = dn[e].first; r; r = dn[r].next) if (dn[r].type == DN_ELEM && CS(r)) { measure(r, &a, &b); mn += a; mx += b; }
        } else
            for (r = dn[e].first; r; r = dn[r].next) if (dn[r].type == DN_ELEM && CS(r)) {
                measure(r, &a, &b);
                if (a > mn) mn = a;
                if (b > mx) mx = b;
            }
        mn += pad; mx += pad;
    } else {
        measure_kids(e, cs, &mn, &mx);
        if (cs->ws == WS_NOWRAP || cs->ws == WS_PRE) mn = mx;
        mn += pad; mx += pad;
    }
    if (cs->maxw.kind == L_LEN && !cs->maxw.pct) {
        int m = (int)cs->maxw.px + (cs->boxsz ? 0 : pad);
        if (mx > m) mx = m;
        if (mn > m) mn = m;
    }
    if (cs->minw.kind == L_LEN && !cs->minw.pct) {
        int m = (int)cs->minw.px + (cs->boxsz ? 0 : pad);
        if (mn < m) mn = m;
        if (mx < m) mx = m;
    }
    if (mx < mn) mx = mn;
    dn[e].mgen = mgen;
    dn[e].minw = mn;
    dn[e].maxw = mx;
    *pmin = mn;
    *pmax = mx;
}

/* ================================================================
 * replaced boxes: pictures, <svg>, fields, video
 * ================================================================ */
static int ctrl_w(struct ctrl *c, int e)
{
    const char *a;
    int size;
    switch (c->kind) {
    case CT_CHECK: case CT_RADIO: return 16;
    case CT_SUBMIT: case CT_BUTTON: case CT_IMAGE: { int w = (c->val ? strlen(c->val) : 0) * 8 + 20; return w > 300 ? 300 : w < 28 ? 28 : w; }
    case CT_SELECT: return (c->rows ? c->rows : 4) * 8 + 30;
    case CT_AREA: size = (a = dom_attr(e, "cols")) ? atoi(a) : 40; if (size < 10) size = 10; if (size > 90) size = 90; return size * 8 + 12;
    default: size = (a = dom_attr(e, "size")) ? atoi(a) : 22; if (size < 6) size = 6; if (size > 60) size = 60; return size * 8 + 12;
    }
}
static int ctrl_h(struct ctrl *c, int e)
{
    const char *a;
    int rows;
    switch (c->kind) {
    case CT_CHECK: case CT_RADIO: return 16;
    case CT_SUBMIT: case CT_BUTTON: case CT_IMAGE: return 24;
    case CT_AREA: rows = (a = dom_attr(e, "rows")) ? atoi(a) : 3; if (rows < 1) rows = 1; if (rows > 12) rows = 12; return rows * 16 + 8;
    default: return 22;
    }
}
static const char *img_src(int e)
{
    const char *s = dom_attr(e, "src"), *ds = dom_attr(e, "data-src"), *ss;
    if (!ds) ds = dom_attr(e, "data-lazy-src");
    if (!ds) ds = dom_attr(e, "data-original");
    if (ds && *ds && (!s || !*s || starts_ci(s, "data:image/gif") || starts_ci(s, "data:image/svg") || strstr_ci(s, "blank") ||
                      strstr_ci(s, "placeholder") || strstr_ci(s, "lazy") || strstr_ci(s, "spacer") || strstr_ci(s, "pixel"))) s = ds;
    if ((!s || !*s || starts_ci(s, "data:image/gif")) && ((ss = dom_attr(e, "srcset")) || (ss = dom_attr(e, "data-srcset")))) {
        static char one[URL_MAX];                        /* (srcset: its first) */
        int k = 0;
        while (*ss == ' ') ss++;
        while (*ss && *ss != ' ' && *ss != ',' && k < URL_MAX - 1) one[k++] = *ss++;
        one[k] = 0;
        if (k) s = one;
    }
    if ((!s || !*s) && dn[e].parent && dn[dn[e].parent].tag == T_picture) {          /* <picture>'s <source> */
        int c;
        for (c = dn[dn[e].parent].first; c; c = dn[c].next)
            if (dn[c].tag == T_source && (ss = dom_attr(c, "srcset"))) {
                static char one2[URL_MAX];
                int k = 0;
                while (*ss == ' ') ss++;
                while (*ss && *ss != ' ' && *ss != ',' && k < URL_MAX - 1) one2[k++] = *ss++;
                one2[k] = 0;
                if (k) { s = one2; break; }
            }
    }
    return s;
}
/* its own size (attributes, CSS, or the picture's), in avail */
static void replaced_size(int e, struct cstyle *cs, int avail, int *pw, int *ph)
{
    int w = -1, h = -1, nw = 0, nh = 0, t = dn[e].tag;
    if (cs->w.kind == L_LEN) w = css_resolve(&cs->w, avail) - (cs->boxsz ? lay_hpad(cs, avail) : 0);
    if (cs->h.kind == L_LEN && !cs->h.pct) h = css_resolve(&cs->h, 0) - (cs->boxsz ? lay_len(&cs->p[0], 0) + lay_len(&cs->p[2], 0) + lay_bw(cs, 0) + lay_bw(cs, 2) : 0);
    if (t == T_img || t == T_svg) {
        if (t == T_svg) {
            if (!svg_size(dstr + dn[e].text, dn[e].tlen, &nw, &nh)) nw = nh = 16;
            {                                            /* (no width/height of its own: an icon's size) */
                const char *aw = dom_attr(e, "width");
                if (!aw && w < 0 && h < 0) { int s = cs->fsize > 16 ? cs->fsize : 16; nh = nw && nh ? s : s; nw = s * (nw ? nw : 1) / (nh ? nh : 1); nw = nw > 64 ? s : nw; nh = s; }
            }
        } else {
            const char *s = img_src(e);
            const char *aw = dom_attr(e, "width"), *ah = dom_attr(e, "height");
            int ci = -1;
            if (aw && atoi(aw) > 0 && ah && atoi(ah) > 0 && (w > 0 || h > 0 || 1)) { nw = atoi(aw); nh = atoi(ah); }
            if ((!nw || !nh || (w < 0 && h < 0 && !aw)) && s && *s) {
                ci = img_get_bg(s, w > 0 ? w : 0, h > 0 ? h : 0, cs->has_bg ? cs->bg : cs->eff_bg);
                if (ci >= 0) { nw = imgc[ci].w; nh = imgc[ci].h; }
            }
            if (!nw || !nh) { nw = aw ? atoi(aw) : 0; nh = ah ? atoi(ah) : 0; }
        }
        if (w < 0 && h < 0) { w = nw; h = nh; }
        else if (w < 0) w = nh ? nw * h / nh : h;
        else if (h < 0) h = nw ? nh * w / nw : w;
    } else if (t == T_input || t == T_select || t == T_textarea || t == T_button) {
        int k = ctrl_for(e);
        if (k >= 0) {
            if (w < 0) w = ctrl_w(&ctrls[k], e);
            if (h < 0) h = ctrl_h(&ctrls[k], e);
            if (ctrls[k].kind == CT_HIDDEN) w = h = 0;
        }
    } else {                                              /* video, iframe, canvas...: a frame */
        const char *aw = dom_attr(e, "width"), *ah = dom_attr(e, "height");
        nw = aw ? atoi(aw) : 300;
        nh = ah ? atoi(ah) : 150;
        if (t == T_audio) { nw = 300; nh = 32; }
        if (w < 0 && h < 0) { w = nw; h = nh; }
        else if (w < 0) w = nh ? nw * h / nh : h;
        else if (h < 0) h = nw ? nh * w / nw : w;
    }
    if (cs->maxw.kind == L_LEN) {
        int m = css_resolve(&cs->maxw, avail);
        if (w > m && m > 0) { if (h > 0 && w > 0) h = h * m / w; w = m; }
    }
    if (cs->maxh.kind == L_LEN && !cs->maxh.pct) {
        int m = (int)cs->maxh.px;
        if (h > m && m > 0) { if (w > 0 && h > 0) w = w * m / h; h = m; }
    }
    if (cs->minw.kind == L_LEN && !cs->minw.pct && w < (int)cs->minw.px) w = (int)cs->minw.px;
    if (w < 0) w = 0;
    if (h < 0) h = 0;
    if (w > 4000) w = 4000;
    if (h > 6000) h = 6000;
    *pw = w;
    *ph = h;
}
/* e drawn into its box (x0, y0, w x h) */
static int js_canvas_item(int e, int x0, int y0, int w, int h, unsigned bg);
static void replaced_draw(int e, struct cstyle *cs, int x0, int y0, int w, int h)
{
    int t = dn[e].tag;
    struct item *it;
    if (w <= 0 || h <= 0) return;
    if (t == T_img) {
        const char *s = img_src(e);
        int ci = s && *s ? img_get_bg(s, w, h, cs->has_bg ? cs->bg : cs->eff_bg) : -1;
        if (ci >= 0) { if (!(w <= 2 && h <= 2)) img_item(ci, x0, y0, w, h, 0); return; }
        {                                                 /* not there: its alt words, in a frame */
            const char *alt = dom_attr(e, "alt");
            if (alt && *alt && w >= 24 && h >= 16) {
                char f[160];
                int i, n, sc = 1;
                font_text(alt, f, sizeof f);
                n = strlen(f);
                if (n > (w - 4) / 8) n = (w - 4) / 8;
                if ((it = new_item(IT_RULE))) { it->x = x0; it->y = y0; it->w = w; it->h = 1; it->color = C_RULE; }
                if ((it = new_item(IT_RULE))) { it->x = x0; it->y = y0 + h - 1; it->w = w; it->h = 1; it->color = C_RULE; }
                if (n > 0 && POOL_ROOM(n) && (it = new_item(IT_TEXT))) {
                    memcpy(pool + npool, f, n);
                    it->text = npool; it->len = n; npool += n;
                    it->x = x0 + 2; it->y = y0 + (h > 16 ? (h - 16) / 2 : 0); it->w = n * 8; it->h = 16; it->scale = sc;
                    it->style = ST_ITAL; it->color = C_GRAY; it->link = cur_link;
                }
                (void)i;
            }
        }
        return;
    }
    if (t == T_svg) {
        int pw, ph;
        unsigned *pix = svg_render(dstr + dn[e].text, dn[e].tlen, w, h, cs->eff_bg, cs->color, &pw, &ph);
        if (!pix) return;
        to16(pix, pw * ph);
        if ((it = new_item(IT_IMAGE))) {
            it->x = x0; it->y = y0; it->w = pw; it->h = ph;
            it->pix = pix; it->own = 1; it->link = cur_link;
        } else free(pix);
        return;
    }
    if (t == T_input || t == T_select || t == T_textarea || t == T_button) {
        int k = ctrl_for(e);
        if (k < 0 || ctrls[k].kind == CT_HIDDEN) return;
        if ((it = new_item(IT_CTRL))) {
            struct ctrl *ct = &ctrls[k];
            it->x = x0; it->y = y0; it->w = w; it->h = h; it->text = k;
            ct->item = nitems - 1;
            ct->fg = cs->color;                           /* (its looks: the page's, if it has them) */
            ct->bg = cs->has_bg ? cs->bg : 0xFFFFFFFFu;
            ct->bd = cs->bw[0] > 0 && cs->bc[0] != 0xFFFFFFFFu ? cs->bc[0] : cs->has_bg ? cs->bg : 0xFFFFFFFFu;
            if (cs->bw[0] == 0 && cs->bw[3] == 0 && !cs->has_bg && (ct->kind == CT_SUBMIT || ct->kind == CT_BUTTON)) ct->bd = 0xFFFFFFFEu;
        }
        return;
    }
    {                                                     /* a frame with its name */
        static const char *what[] = { "[video]", "[frame]", "[canvas]", "[object]", "[audio]" };
        const char *wd = t == T_video ? what[0] : t == T_iframe ? what[1] : t == T_canvas ? what[2] : t == T_audio ? what[4] : what[3];
        int n = strlen(wd);
        const char *poster = t == T_video ? dom_attr(e, "poster") : 0;
        if (poster && *poster) { int ci = img_get(poster, w, h); if (ci >= 0) { img_item(ci, x0, y0, w, h, 1); return; } }
        if (t == T_canvas) { js_canvas_item(e, x0, y0, w, h, cs->has_bg ? cs->bg : cs->eff_bg); return; }
        if ((it = new_item(IT_BOX))) { it->x = x0; it->y = y0; it->w = w; it->h = h; it->color = RGB(232, 234, 240); }
        if (POOL_ROOM(n) && (it = new_item(IT_TEXT))) {
            memcpy(pool + npool, wd, n);
            it->text = npool; it->len = n; npool += n;
            it->x = x0 + (w - n * 8) / 2; it->y = y0 + (h - 16) / 2; it->w = n * 8; it->h = 16; it->scale = 1;
            it->color = C_GRAY; it->link = cur_link;
        }
    }
}

/* ================================================================
 * inline text
 * ================================================================ */
static unsigned lay_upper(unsigned u)
{
    if (u >= 'a' && u <= 'z') return u - 32;
    if (u >= 0x430 && u <= 0x44F) return u - 0x20;
    if (u == 0x451) return 0x401;
    if (u >= 0xE0 && u <= 0xFE && u != 0xF7) return u - 0x20;
    return u;
}
static unsigned lay_lower(unsigned u)
{
    if (u >= 'A' && u <= 'Z') return u + 32;
    if (u >= 0x410 && u <= 0x42F) return u + 0x20;
    if (u == 0x401) return 0x451;
    if (u >= 0xC0 && u <= 0xDE && u != 0xD7) return u + 0x20;
    return u;
}
static int lay_img_depth;                                 /* (over a background picture: no color fixes) */
/* the text's look, from the element it's in */
static void text_style(struct cstyle *cs)
{
    unsigned c = cs->color;
    bold = cs->bold;
    ital = cs->ital;
    under = cs->under;
    scale = lay_scale(cs);
    pre = cs->ws == WS_PRE || cs->ws == WS_PRE_WRAP || cs->ws == WS_PRE_LINE ? (cs->ws == WS_PRE_LINE ? 2 : 1) : 0;
    nowrap_ws = cs->ws == WS_NOWRAP || cs->ws == WS_PRE;
    if (!lay_img_depth) {                                 /* (unreadable on its background: made readable) */
        unsigned bg = cs->has_bg ? cs->bg : cs->eff_bg;
        int d = luma(c) - luma(bg);
        if (d < 50 && d > -50) c = luma(bg) < 128 ? RGB(232, 234, 238) : (cur_link >= 0 ? C_LINK : C_TEXT);
    }
    text_col = c;
}
static void lay_text(int t, struct cstyle *cs)
{
    const char *s = dstr + dn[t].text;
    int n = dn[t].tlen, p = 0, cap = cs->ttrans == TT_CAP, start = 1;
    if (cs->hidden) {                                     /* visibility: hidden - room, no letters */
        int k = 0;
        while (p < n) { dom_u8(s, n, &p); k++; }
        (void)k;
        return;
    }
    flush_word();
    text_style(cs);
    while (p < n) {
        unsigned u = dom_u8(s, n, &p);
        if (u == '\t' && !pre) u = ' ';
        if (u == '\n' && pre == 2) { flush_word(); end_line(1); continue; }    /* (pre-line) */
        if (pre == 2 && u == ' ') u = ' ';
        if (cs->ttrans == TT_UPPER) u = lay_upper(u);
        else if (cs->ttrans == TT_LOWER) u = lay_lower(u);
        else if (cap) { if (start && u > ' ') u = lay_upper(u); start = u == ' ' || u == '\n' || u == '-'; }
        if (pre == 2 && u == ' ') { flush_word(); pending_space = 1; continue; }
        put_char(u);
    }
    flush_word();
}

/* ---- inline backgrounds (spans, <mark>, <code>): boxes behind their
 * line pieces, made when the lines are where they'll stay ---- */
#define IBG_MAX 512
static struct { int from, to, pad; unsigned color; unsigned char layer; } ibg[IBG_MAX];
static int nibg;
static void ibg_flush(int from_rec)
{
    int r;
    for (r = from_rec; r < nibg; r++) {
        int i = ibg[r].from, end = ibg[r].to;
        while (i < end) {                                /* each line's piece */
            int x0 = 1 << 30, x1 = -1, y0 = 1 << 30, y1 = -1, ly;
            if (items[i].kind != IT_TEXT && items[i].kind != IT_IMAGE) { i++; continue; }
            ly = items[i].y;
            while (i < end && (items[i].kind != IT_TEXT && items[i].kind != IT_IMAGE ? 1 : items[i].y + items[i].h > ly && items[i].y < ly + 16 * 3)) {
                struct item *it = &items[i];
                if (it->kind == IT_TEXT || it->kind == IT_IMAGE) {
                    if (it->x < x0) x0 = it->x;
                    if (it->x + it->w > x1) x1 = it->x + it->w;
                    if (it->y < y0) y0 = it->y;
                    if (it->y + it->h > y1) y1 = it->y + it->h;
                    if (it->y != ly && (it->y >= ly + 16 || it->y + it->h <= ly)) break;
                }
                i++;
            }
            if (x1 > x0) {
                struct item *b = new_item(IT_BOX);
                if (b) {
                    b->x = x0 - ibg[r].pad; b->w = x1 - x0 + 2 * ibg[r].pad;
                    b->y = y0 - 1; b->h = y1 - y0 + 2;
                    b->color = ibg[r].color;
                    b->layer = ibg[r].layer;
                }
            }
        }
    }
    nibg = from_rec;
}

/* ================================================================
 * absolutely positioned boxes: laid out when their containing box is done
 * ================================================================ */
#define ABS_MAX 512
static struct { int e, sx, sy, cb; } absq[ABS_MAX];
static int nabs;
static int pos_stack[64], npos;                           /* the positioned boxes we're in */
static int box_x0[1], box_y0[1];
static void abs_place(int k, int cbx, int cby, int cbw, int cbh)
{
    int e = absq[k].e;
    struct cstyle *cs = CS(e);
    int l = cs->pos[3].kind == L_LEN, r = cs->pos[1].kind == L_LEN, t = cs->pos[0].kind == L_LEN, b = cs->pos[2].kind == L_LEN;
    int w, start = nitems, hgt, bx, by;
    int sx = x, sy = y, sls = line_start, sll = line_left, slr = line_right, scl = cb_l, scr = cb_r, sps = pending_space;
    int slg = last_gap, sta = talign_cur, sfb = fl_base, snf = nfl, slink = cur_link;
    unsigned char slayer = cur_layer;
    int ml = lay_len(&cs->m[3], cbw), mr = lay_len(&cs->m[1], cbw);
    if (cs->w.kind == L_LEN) w = css_resolve(&cs->w, cbw) + (cs->boxsz ? 0 : lay_hpad(cs, cbw));
    else if (l && r) w = cbw - css_resolve(&cs->pos[3], cbw) - css_resolve(&cs->pos[1], cbw) - ml - mr;
    else {
        int mn, mx;
        measure(e, &mn, &mx);
        w = mx < cbw - ml - mr ? mx : cbw - ml - mr;
        if (w < mn) w = mn;
    }
    if (w < 0) w = 0;
    bx = l ? cbx + css_resolve(&cs->pos[3], cbw) + ml : r ? cbx + cbw - css_resolve(&cs->pos[1], cbw) - w - mr : absq[k].sx + ml;
    by = t ? cby + css_resolve(&cs->pos[0], cbh) : absq[k].sy;
    if (bx < 0 && bx + w > 0 && cs->position == P_FIXED) bx = 0;
    flush_word();
    cur_layer = slayer + 1;
    x = bx; y = by;
    line_start = nitems;
    nfl = fl_base = snf;
    last_gap = 99;
    lay_fixed_w = 1;
    lay_block(e, bx - ml, bx + w + mr, 0);
    hgt = y - by;
    if (!t && b) {                                       /* (by its bottom: moved up) */
        int ny = cby + cbh - css_resolve(&cs->pos[2], cbh) - hgt, i;
        for (i = start; i < nitems; i++) items[i].y += ny - by;
    }
    x = sx; y = sy; line_start = sls; line_left = sll; line_right = slr; cb_l = scl; cb_r = scr; pending_space = sps;
    last_gap = slg; talign_cur = sta; fl_base = sfb; nfl = snf; cur_layer = slayer; cur_link = slink;
    (void)box_x0; (void)box_y0;
}
/* the boxes waiting for e (the box they're positioned in) - or for the page (e 0) */
static void abs_flush(int e, int cbx, int cby, int cbw, int cbh)
{
    int k, n0 = nabs;
    for (k = 0; k < nabs; k++) {
        if (absq[k].cb != e) continue;
        absq[k].cb = -1;
        abs_place(k, cbx, cby, cbw, cbh);
    }
    {                                                    /* (the done ones: off the list) */
        int w2 = 0;
        for (k = 0; k < nabs; k++) if (absq[k].cb != -1) absq[w2++] = absq[k];
        nabs = w2 < n0 ? w2 : nabs;
        nabs = w2;
    }
}

/* ================================================================
 * blocks
 * ================================================================ */
struct boxrec { int bg, bgi, br[4], top, h, x, w; };
static struct boxrec last_box;
/* a box stretched to h (a flex row's, a table row's) */
static void box_stretch(struct boxrec *b, int h)
{
    if (h <= b->h) return;
    if (b->bg >= 0) items[b->bg].h = h;
    if (b->bgi >= 0 && items[b->bgi].h < h) items[b->bgi].h = items[b->bgi].h;      /* (the picture stays as made) */
    if (b->br[1] >= 0) items[b->br[1]].h = h;
    if (b->br[3] >= 0) items[b->br[3]].h = h;
    if (b->br[2] >= 0) items[b->br[2]].y = b->top + h - items[b->br[2]].h;
    b->h = h;
}
static void shift_items(int from, int to, int dx, int dy)
{
    int i;
    for (i = from; i < to; i++) { items[i].x += dx; items[i].y += dy; }
}
/* what's outside x0..x1, y0..y1 (overflow: hidden): not shown */
static void clip_items(int from, int x0, int y0, int x1, int y1)
{
    int i;
    for (i = from; i < nitems; i++) {
        struct item *it = &items[i];
        if (it->kind == IT_NONE || it->kind == IT_GROUP) continue;
        if (it->x >= x1 || it->x + it->w <= x0 || it->y >= y1 || it->y + it->h <= y0) { it->kind = IT_NONE; continue; }
        if (it->kind == IT_BOX || it->kind == IT_RULE) {
            if (it->x < x0) { it->w -= x0 - it->x; it->x = x0; }
            if (it->x + it->w > x1) it->w = x1 - it->x;
            if (it->y < y0) { it->h -= y0 - it->y; it->y = y0; }
            if (it->y + it->h > y1) it->h = y1 - it->y;
        }
    }
}
static int list_number(int e)
{
    int n = 1, s, par = dn[e].parent;
    const char *v = dom_attr(e, "value");
    if (v) return atoi(v);
    if (par && (v = dom_attr(par, "start"))) n = atoi(v);
    for (s = dn[e].prev; s; s = dn[s].prev) if (dn[s].type == DN_ELEM && CS(s) && CS(s)->display == D_LIST_ITEM) n++;
    if (par && dom_attr(par, "reversed")) {
        int cnt = 0, c;
        for (c = dn[par].first; c; c = dn[c].next) if (dn[c].type == DN_ELEM && CS(c) && CS(c)->display == D_LIST_ITEM) cnt++;
        n = cnt - (n - 1);
    }
    return n;
}
static void list_marker(int e, struct cstyle *cs)
{
    char mark[16];
    struct item *it;
    int k = 0, n;
    if (cs->lstyle == LS_NONE) return;
    n = list_number(e);
    switch (cs->lstyle) {
    case LS_DISC: mark[k++] = 7; break;
    case LS_CIRCLE: mark[k++] = (char)0xF9; break;
    case LS_SQUARE: mark[k++] = (char)0xFE; break;
    case LS_LALPHA: case LS_UALPHA: mark[k++] = (cs->lstyle == LS_LALPHA ? 'a' : 'A') + (n - 1) % 26; mark[k++] = '.'; break;
    case LS_LROMAN: case LS_UROMAN: {
        static const char *r[] = { "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii", "xiii", "xiv", "xv",
                                   "xvi", "xvii", "xviii", "xix", "xx" };
        const char *t = n >= 1 && n <= 20 ? r[n - 1] : "?";
        while (*t) mark[k++] = cs->lstyle == LS_UROMAN ? *t++ - 32 : *t++;
        mark[k++] = '.';
        break;
    }
    default: {
        char t[8];
        int j = 0, v = n < 0 ? -n : n;
        do { t[j++] = '0' + v % 10; v /= 10; } while (v && j < 7);
        if (n < 0) mark[k++] = '-';
        while (j) mark[k++] = t[--j];
        mark[k++] = '.';
    }
    }
    if (POOL_ROOM(k) && (it = new_item(IT_TEXT))) {
        int sc = lay_scale(cs);
        memcpy(pool + npool, mark, k);
        it->text = npool; it->len = k; npool += k;
        it->x = line_left - k * 8 * sc - 6;
        it->w = k * 8 * sc; it->h = 16 * sc; it->scale = sc;
        it->color = cs->color;
    }
}

/* a block-level box: e laid out at y, between al and ar (its margins
 * inside those); shrink: as narrow as its content lets it (floats,
 * inline-blocks) */
static int lay_root;
static void lay_flex(int e, struct cstyle *cs, int cw);
static void lay_grid(int e, struct cstyle *cs, int cw);
static void lay_table(int e, struct cstyle *cs, int cw);
static void lay_block(int e, int al, int ar, int shrink)
{
    struct cstyle *cs = CS(e);
    int avail = ar - al, ml, mr, mt, mb, bl, br, bt, bb, pl, pr, pt, pb, cw, ow, bx, top, ctop, start = nitems, i;
    int s_cbl = cb_l, s_cbr = cb_r, s_ta = talign_cur, s_fb = fl_base, s_nfl = nfl, s_ibg = nibg, s_npos = npos;
    int bfc, h, ch, is_ctrl;
    struct boxrec rec;
    int s_node = lay_node;
    if (lay_depth > 200) return;
    lay_depth++;
    lay_node = e;
    rec.bg = rec.bgi = rec.br[0] = rec.br[1] = rec.br[2] = rec.br[3] = -1;
    ml = cs->m[3].kind == L_AUTO ? 0 : lay_len(&cs->m[3], avail);
    mr = cs->m[1].kind == L_AUTO ? 0 : lay_len(&cs->m[1], avail);
    mt = lay_len(&cs->m[0], avail);
    mb = lay_len(&cs->m[2], avail);
    bl = lay_bw(cs, 3); br = lay_bw(cs, 1); bt = lay_bw(cs, 0); bb = lay_bw(cs, 2);
    pl = lay_len(&cs->p[3], avail); pr = lay_len(&cs->p[1], avail); pt = lay_len(&cs->p[0], avail); pb = lay_len(&cs->p[2], avail);
    if (pl < 0) pl = 0;
    if (pr < 0) pr = 0;
    if (pt < 0) pt = 0;
    if (pb < 0) pb = 0;
    if (e == dom_body && (CS(dom_html)->has_bg || cs->has_bg)) { /* (the page's own color: the canvas) */ }
    /* its width */
    if (lay_fixed_w) {
        lay_fixed_w = 0;
        cw = avail - ml - mr - pl - pr - bl - br;
        if (cw < 0) cw = 0;
        shrink = 1;                                       /* (no margin: auto centering) */
        goto width_done;
    }
    if (cs->w.kind == L_LEN) {
        cw = css_resolve(&cs->w, avail);
        if (cs->boxsz) cw -= pl + pr + bl + br;
    } else if (shrink || cs->w.kind == L_CONTENT || (cs->display == D_TABLE && dn[e].tag == T_table)) {
        int mn, mx, room = avail - ml - mr;
        measure(e, &mn, &mx);
        ow = mx < room ? mx : room;
        if (ow < mn) ow = mn;
        cw = ow - pl - pr - bl - br;
    } else cw = avail - ml - mr - pl - pr - bl - br;
    if (cs->maxw.kind == L_LEN) {
        int m = css_resolve(&cs->maxw, avail) - (cs->boxsz ? pl + pr + bl + br : 0);
        if (cw > m) cw = m;
    }
    if (cs->minw.kind == L_LEN) {
        int m = css_resolve(&cs->minw, avail) - (cs->boxsz ? pl + pr + bl + br : 0);
        if (cw < m) cw = m;
    }
    if (cw < 0) cw = 0;
width_done:
    ow = bl + pl + cw + pr + br;
    if (!shrink) {                                        /* margin: auto - centered (or to a side) */
        int free_ = avail - ow - ml - mr;
        if (cs->m[3].kind == L_AUTO && cs->m[1].kind == L_AUTO) { if (free_ > 0) ml += free_ / 2; }
        else if (cs->m[3].kind == L_AUTO) { if (free_ > 0) ml += free_; }
        else if (dn[e].tag == T_table && dom_attr(e, "align") && starts_ci(dom_attr(e, "align"), "center") && free_ > 0) ml += free_ / 2;
    }
    bx = al + ml;
    /* its top: the margin above (collapsed with the one before) */
    if (cs->clear) {
        int fb = fl_bottom(cs->clear == 3 ? 3 : cs->clear);
        if (fb > y) { y = fb; last_gap = 0; }
    }
    if (mt >= 0) { if (mt > last_gap) { y += mt - last_gap; last_gap = mt; } }
    else { y += mt; last_gap = 0; }
    top = y;
    is_ctrl = dn[e].tag == T_input || dn[e].tag == T_select || dn[e].tag == T_textarea || dn[e].tag == T_button;
    if (cs->has_bg && !(e == lay_root && !cs->position) && !is_ctrl) {
        struct item *it = new_item(IT_BOX);
        if (it) { it->x = bx; it->y = top; it->w = ow; it->color = cs->bg; rec.bg = nitems - 1; }
    }
    if (cs->bg_url && !css_reader) {                      /* a background picture: covering it */
        struct item *it = new_item(IT_BOX);
        if (it) { it->x = bx; it->y = top; it->w = ow; it->h = 0; it->color = 0xFFFFFFFFu; rec.bgi = nitems - 1; it->kind = IT_NONE; }
    }
    y += bt + pt;
    ctop = y;
    last_gap = bt || pt ? 0 : last_gap;
    if (bt || pt) last_gap = 0;
    cb_l = bx + bl + pl;
    cb_r = cb_l + cw;
    talign_cur = cs->talign;
    bfc = e == lay_root || cs->flt != F_NONE || (cs->overflow != OV_VISIBLE) || cs->display == D_FLEX || cs->display == D_GRID ||
          cs->display == D_INLINE_BLOCK || cs->display == D_CELL || cs->display == D_INLINE_FLEX || cs->display == D_INLINE_GRID ||
          cs->position == P_ABSOLUTE || cs->position == P_FIXED || cs->display == D_TABLE;
    if (bfc) fl_base = nfl;
    if (cs->position != P_STATIC && npos < 64) pos_stack[npos++] = e;
    if (cs->bg_url) lay_img_depth++;
    x = cb_l;
    line_start = nitems;
    pending_space = 0;
    line_room();
    if (cs->tindent.kind == L_LEN && cs->tindent.px > -900) x += css_resolve(&cs->tindent, cw);
    if (cs->display == D_LIST_ITEM) list_marker(e, cs);
    if (lay_replaced(e)) {                                /* (a picture or field as a block) */
        int rw, rh;
        replaced_size(e, cs, cw, &rw, &rh);
        if (cs->w.kind != L_LEN && !shrink && dn[e].tag != T_img && dn[e].tag != T_svg && dn[e].tag != T_iframe) rw = rw < cw ? rw : cw;
        if (is_ctrl) {                                    /* (a field: its whole box is the field) */
            if (!shrink || cs->w.kind == L_LEN || cs->display == D_BLOCK) rw = cw;
            replaced_draw(e, cs, bx, top, rw + pl + pr + bl + br, rh + pt + pb + bt + bb);
        } else replaced_draw(e, cs, cb_l, y, rw, rh);
        y += rh;
        line_start = nitems;                              /* (placed: not a line's, for end_line to move) */
        if (rw > cw && !shrink) cw = rw;
    } else switch (cs->display) {
    case D_FLEX: case D_INLINE_FLEX: lay_flex(e, cs, cw); break;
    case D_GRID: case D_INLINE_GRID: lay_grid(e, cs, cw); break;
    case D_TABLE: case D_INLINE_TABLE: lay_table(e, cs, cw); break;
    default: lay_flow(e); break;
    }
    flush_word();
    end_line(0);
    ibg_flush(s_ibg);
    if (bfc) { int fb = fl_bottom(0); if (fb > y) y = fb; }
    ch = y - ctop;
    if (cs->h.kind == L_LEN && (!cs->h.pct || e == lay_root)) {
        h = css_resolve(&cs->h, CSS_VH) - (cs->boxsz ? pt + pb + bt + bb : 0);
        if (cs->overflow != OV_VISIBLE && h < ch) { clip_items(start, bx, top, bx + ow, ctop + h + pb); ch = h; }
        else if (h > ch) ch = h;
    }
    if (cs->minh.kind == L_LEN && !cs->minh.pct) {
        h = css_resolve(&cs->minh, CSS_VH) - (cs->boxsz ? pt + pb + bt + bb : 0);
        if (h > ch) ch = h;
    }
    if (cs->maxh.kind == L_LEN && !cs->maxh.pct && cs->overflow != OV_VISIBLE) {
        h = css_resolve(&cs->maxh, CSS_VH);
        if (h < ch) { clip_items(start, bx, top, bx + ow, ctop + h + pb); ch = h; }
    }
    if (cs->overflow != OV_VISIBLE && cs->w.kind == L_LEN) clip_items(start, bx, top, bx + ow, 1 << 30);
    y = ctop + ch + pb + bb;
    rec.top = top;
    rec.h = y - top;
    rec.x = bx;
    rec.w = ow;
    if (rec.bg >= 0) items[rec.bg].h = y - top;
    if (rec.bgi >= 0) {                                   /* the picture, now the box's size is known */
        const char *u = css_pool + cs->bg_url;
        int ci = img_get(u, ow, y - top);
        if (ci >= 0 && ow > 0 && y > top) {
            struct item *it = img_item(ci, bx, top, ow, y - top > 2400 ? 2400 : y - top, 1);
            if (it) {                                     /* (into the box's place: under what's in it) */
                unsigned char lay = items[rec.bgi].layer;
                items[rec.bgi] = *it;
                items[rec.bgi].layer = lay;
                items[rec.bgi].style = ST_BGPIC;
                items[rec.bgi].link = -1;
                nitems--;
            }
        }
    }
    if (!is_ctrl) {                                       /* its borders */
        int s;
        for (s = 0; s < 4; s++) {
            int bw2 = s == 0 ? bt : s == 1 ? br : s == 2 ? bb : bl;
            struct item *it;
            if (!bw2) continue;
            if (!(it = new_item(IT_RULE))) break;
            it->color = cs->bc[s];
            if (s == 0) { it->x = bx; it->y = top; it->w = ow; it->h = bw2; }
            else if (s == 2) { it->x = bx; it->y = y - bw2; it->w = ow; it->h = bw2; }
            else if (s == 3) { it->x = bx; it->y = top; it->w = bw2; it->h = y - top; }
            else { it->x = bx + ow - bw2; it->y = top; it->w = bw2; it->h = y - top; }
            rec.br[s] = nitems - 1;
        }
    }
    dn[e].bx = bx; dn[e].by = top; dn[e].bw = ow; dn[e].bh = y - top;
    if (cs->position != P_STATIC) {                       /* the boxes positioned in it */
        npos = s_npos;
        abs_flush(e, bx + bl, top + bt, ow - bl - br, y - top - bt - bb);
    }
    if (cs->bg_url) lay_img_depth--;
    if (cs->position == P_RELATIVE || cs->position == P_STICKY) {
        int dx = cs->pos[3].kind == L_LEN ? css_resolve(&cs->pos[3], avail) : cs->pos[1].kind == L_LEN ? -css_resolve(&cs->pos[1], avail) : 0;
        int dy = cs->pos[0].kind == L_LEN && !cs->pos[0].pct ? css_resolve(&cs->pos[0], 0) :
                 cs->pos[2].kind == L_LEN && !cs->pos[2].pct ? -css_resolve(&cs->pos[2], 0) : 0;
        if (cs->position == P_RELATIVE && (dx || dy) && dx > -2000 && dx < 2000 && dy > -2000 && dy < 2000) {
            shift_items(start, nitems, dx, dy);
            rec.top += dy;
        }
    }
    last_box = rec;
    cb_l = s_cbl; cb_r = s_cbr; talign_cur = s_ta;
    if (bfc) { fl_base = s_fb; nfl = s_nfl; }
    npos = s_npos;
    for (i = 0; i < 0; i++) ;
    /* below it: its bottom margin */
    last_gap = 0;
    if (mb > 0) { y += mb; last_gap = mb; }
    else if (mb < 0) y += mb;
    x = cb_l;
    line_start = nitems;
    line_room();
    lay_node = s_node;
    lay_depth--;
}

/* a float: to its side, the lines go around it */
static void lay_float(int c)
{
    struct cstyle *cs = CS(c);
    int sy = y, sx = x, sls = line_start, slg = last_gap, mn, mx, w, room = cb_r - cb_l, fx, fy, k, placed = 0;
    int ml = lay_len(&cs->m[3], room), mr = lay_len(&cs->m[1], room);
    if (cs->w.kind == L_LEN) w = css_resolve(&cs->w, room) + (cs->boxsz ? 0 : lay_hpad(cs, room)) + ml + mr;
    else if (lay_replaced(c)) { int rw, rh; replaced_size(c, cs, room, &rw, &rh); w = rw + lay_hpad(cs, room) + ml + mr; }
    else {
        measure(c, &mn, &mx);
        w = mx + ml + mr < room ? mx + ml + mr : room;
        if (w < mn + ml + mr) w = mn + ml + mr;
    }
    if (w > room) w = room;
    fy = line_start == nitems ? y : y;                    /* (where the line is) */
    for (k = 0; k < 50 && !placed; k++) {                 /* down until there's room beside the others */
        int l, r;
        fl_bounds(fy, 16, cb_l, cb_r, &l, &r);
        if (r - l >= w || (l == cb_l && r == cb_r)) { fx = cs->flt == F_LEFT ? l : r - w; placed = 1; break; }
        {
            int i, nb = 1 << 30;
            for (i = fl_base; i < nfl; i++) if (fl[i].y1 > fy && fl[i].y1 < nb) nb = fl[i].y1;
            if (nb == 1 << 30) break;
            fy = nb;
        }
    }
    if (!placed) fx = cs->flt == F_LEFT ? cb_l : cb_r - w;
    flush_word();
    {
        int s_cbl = cb_l, s_cbr = cb_r, sll = line_left, slr = line_right, sps = pending_space, sta = talign_cur;
        int start = nitems, snfl = nfl, sfb = fl_base, h;
        y = fy;
        last_gap = 99;
        line_start = nitems;
        fl_base = nfl;
        lay_fixed_w = 1;
        lay_block(c, fx, fx + w, 0);
        h = y - fy;
        fl_base = sfb;
        nfl = snfl;
        cb_l = s_cbl; cb_r = s_cbr; line_left = sll; line_right = slr; pending_space = sps; talign_cur = sta;
        (void)start;
        if (nfl < FL_MAX) {
            fl[nfl].x0 = fx; fl[nfl].x1 = fx + w; fl[nfl].y0 = fy; fl[nfl].y1 = fy + h; fl[nfl].side = cs->flt;
            nfl++;
        }
    }
    y = sy; x = sx; line_start = sls; last_gap = slg;
    {                                                     /* this line: around it now */
        int l, r;
        fl_bounds(y, 16, cb_l, cb_r, &l, &r);
        line_right = r;
        if (l > line_left) {
            int dx = l - line_left, i;
            for (i = line_start; i < nitems; i++) if (items[i].layer == cur_layer && items[i].y >= y - 1) items[i].x += 0;
            line_left = l;
            if (x < l) x = l;
            (void)dx;
        }
    }
}

/* an inline-block (or picture, field) on the line */
static void lay_atomic(int c)
{
    struct cstyle *cs = CS(c);
    int room = line_right - line_left, w, gi, sy, sx, sls, h, ml, mr;
    int s_cbl = cb_l, s_cbr = cb_r, sll = line_left, slr = line_right, sta = talign_cur, slg = last_gap, sfb = fl_base;
    struct item *g;
    flush_word();
    ml = lay_len(&cs->m[3], room);
    mr = lay_len(&cs->m[1], room);
    if (lay_replaced(c)) {
        int rw, rh;
        replaced_size(c, cs, cb_r - cb_l, &rw, &rh);
        w = rw + lay_hpad(cs, room) + ml + mr;
        if (!lay_hpad(cs, room) && !cs->has_bg && !ml && !mr && (dn[c].tag == T_img || dn[c].tag == T_svg) && rw > 0 && rh > 0) {
            if (pending_space && x > line_left) x += 8 * scale;            /* (a plain picture: an item of the line) */
            pending_space = 0;
            if (x + rw > line_right && x > line_left) end_line(0);
            if (rw > line_right - line_left && dn[c].tag == T_img) { rh = rh * (line_right - line_left) / rw; rw = line_right - line_left; }
            {
                int n0 = nitems;
                replaced_draw(c, cs, x, y, rw, rh);
                if (nitems == n0 + 1) {
                    if (cs->valign == VA_MIDDLE) items[n0].style |= 0;
                    dn[c].bx = x; dn[c].by = y; dn[c].bw = rw; dn[c].bh = rh;
                    x += rw;
                    return;
                }
                if (nitems > n0) {                          /* (more than one: a group) */
                    int k;
                    struct item tmp;
                    if (!(g = new_item(IT_GROUP))) return;
                    tmp = *g;
                    for (k = nitems - 1; k > n0; k--) items[k] = items[k - 1];
                    items[n0] = tmp;
                    items[n0].x = x; items[n0].y = y; items[n0].w = rw; items[n0].h = rh; items[n0].len = nitems - n0 - 1;
                    for (k = 0; k < nctrls; k++) if (ctrls[k].item >= n0 && ctrls[k].item < nitems) ctrls[k].item++;
                    x += rw;
                }
                return;
            }
        }
    } else if (cs->w.kind == L_LEN) w = css_resolve(&cs->w, cb_r - cb_l) + (cs->boxsz ? 0 : lay_hpad(cs, room)) + ml + mr;
    else {
        int mn, mx;
        measure(c, &mn, &mx);
        mn += ml + mr; mx += ml + mr;
        w = mx < cb_r - cb_l ? mx : cb_r - cb_l;
        if (w < mn) w = mn;
    }
    if (pending_space && x > line_left) x += 8 * scale;
    pending_space = 0;
    if (x + w > line_right && x > line_left) end_line(0);
    gi = nitems;
    if (!(g = new_item(IT_GROUP))) return;
    sy = y; sx = x; sls = line_start;
    g->x = x; g->y = y; g->w = w;
    last_gap = 99;
    line_start = nitems;
    fl_base = nfl;
    {
        int sbold = bold, sital = ital, sunder = under, sscale = scale, spre = pre, snw = nowrap_ws;
        unsigned scol = text_col;
        lay_fixed_w = 1;
        lay_block(c, x, x + w, 0);
        bold = sbold; ital = sital; under = sunder; scale = sscale; pre = spre; nowrap_ws = snw; text_col = scol;
    }
    h = y - sy;
    items[gi].h = h > 0 ? h : 1;
    items[gi].len = nitems - gi - 1;
    if (cs->valign == VA_MIDDLE) items[gi].style = 1;
    else if (cs->valign == VA_TOP) items[gi].style = 2;
    fl_base = sfb;
    cb_l = s_cbl; cb_r = s_cbr; line_left = sll; line_right = slr; talign_cur = sta; last_gap = slg;
    y = sy; line_start = sls;
    x = sx + w;
}

/* an inline element: its children in the line */
static void lay_inline_el(int c)
{
    struct cstyle *cs = CS(c);
    int slink = cur_link, start = nitems, lpad = 0, rpad = 0, s_node;
    if (dn[c].tag == T_br) { flush_word(); text_style(cs); end_line(1); return; }
    if (dn[c].tag == T_wbr) return;
    s_node = lay_node;
    lay_node = c;
    if (dn[c].tag == T_a || dn[c].tag == T_area) {
        const char *h = dom_attr(c, "href");
        if (h) cur_link = add_link(h);
    }
    lpad = lay_len(&cs->m[3], 0) + lay_len(&cs->p[3], 0) + lay_bw(cs, 3);
    rpad = lay_len(&cs->m[1], 0) + lay_len(&cs->p[1], 0) + lay_bw(cs, 1);
    if (lpad > 0 && lpad < 200) { flush_word(); if (pending_space && x > line_left) x += 8 * scale; pending_space = 0; x += lpad; }
    {
        int k;
        for (k = dn[c].first; k; k = dn[k].next) lay_node_inline(k);
    }
    if (rpad > 0 && rpad < 200) { flush_word(); x += rpad; }
    if (cs->has_bg && nibg < IBG_MAX && cs->bg != cs->eff_bg) {
        flush_word();
        ibg[nibg].from = start; ibg[nibg].to = nitems; ibg[nibg].color = cs->bg;
        ibg[nibg].pad = lay_len(&cs->p[3], 0) > 6 ? 6 : lay_len(&cs->p[3], 0);
        ibg[nibg].layer = cur_layer;
        nibg++;
    }
    if (cs->bw[2] && cs->bc[2] != 0xFFFFFFFFu && dn[c].tag != T_a) { flush_word(); }
    cur_link = slink;
    lay_node = s_node;
    flush_word();
    if (start < nitems) {                                 /* (its box: around what's in it) */
        int i, x0 = 1 << 30, y0 = 1 << 30, x1 = -(1 << 30), y1 = -(1 << 30);
        for (i = start; i < nitems; i++) {
            struct item *it = &items[i];
            if (it->kind == IT_NONE || it->kind == IT_GROUP) continue;
            if (it->x < x0) x0 = it->x;
            if (it->y < y0) y0 = it->y;
            if (it->x + it->w > x1) x1 = it->x + it->w;
            if (it->y + it->h > y1) y1 = it->y + it->h;
        }
        if (x1 > x0) { dn[c].bx = x0; dn[c].by = y0; dn[c].bw = x1 - x0; dn[c].bh = y1 - y0; }
        else { dn[c].bx = items[start].x; dn[c].by = items[start].y; }
    } else { dn[c].bx = x; dn[c].by = y; }
}

/* a node in the line (text, or an element of any kind) */
static void lay_node_inline(int c)
{
    struct cstyle *cs;
    if (dn[c].type == DN_TEXT) {
        int p = dn[c].parent;
        if (p && dn[p].type == DN_ELEM && CS(p)) lay_text(c, CS(p));
        return;
    }
    if (dn[c].type != DN_ELEM) return;
    cs = CS(c);
    if (!cs || lay_hidden(c, cs)) return;
    if (cs->position == P_ABSOLUTE || cs->position == P_FIXED) {
        if (nabs < ABS_MAX) {
            absq[nabs].e = c;
            absq[nabs].sx = x;
            absq[nabs].sy = y;
            absq[nabs].cb = cs->position == P_FIXED || !npos ? 0 : pos_stack[npos - 1];
            nabs++;
        }
        return;
    }
    if (cs->flt != F_NONE && cs->display != D_CONTENTS) { lay_float(c); return; }
    if (cs->display == D_CONTENTS) { int k; for (k = dn[c].first; k; k = dn[k].next) lay_node_inline(k); return; }
    if (lay_is_block(cs)) {
        flush_word();
        end_line(0);
        lay_block(c, cb_l, cb_r, 0);
        return;
    }
    if (dn[c].tag == T_img) {                             /* a picture that isn't there: its words */
        int rw, rh;
        replaced_size(c, cs, cb_r - cb_l, &rw, &rh);
        if (!rw || !rh || (img_src(c) && img_get_bg(img_src(c), 0, 0, cs->has_bg ? cs->bg : cs->eff_bg) < 0 && rw < 24)) {
            const char *alt = dom_attr(c, "alt");
            if (alt && *alt) {
                int p = 0, n = strlen(alt);
                flush_word();
                text_style(cs);
                ital = 1;
                if (pending_space || x > line_left) pending_space = 1;
                while (p < n) put_char(dom_u8(alt, n, &p));
                flush_word();
                pending_space = 1;
            }
            return;
        }
    }
    if (cs->display == D_INLINE_BLOCK || cs->display == D_INLINE_FLEX || cs->display == D_INLINE_GRID ||
        cs->display == D_INLINE_TABLE || lay_replaced(c)) { lay_atomic(c); return; }
    lay_inline_el(c);
}

/* a block's children: blocks one under another, the rest in lines */
static void lay_flow(int e)
{
    int c;
    for (c = dn[e].first; c; c = dn[c].next) lay_node_inline(c);
}

/* ================================================================
 * flex
 * ================================================================ */
struct fitem { int e, basis, mn, mx, w, h, x, y, ml, mr, mt, mb, start, end; float grow, shrink; struct boxrec box; int order, text; };
static int fit_cmp_order(struct fitem *a, struct fitem *b) { return a->order - b->order; }
static void lay_flex(int e, struct cstyle *cs, int cw)
{
    struct fitem *it;
    int n = 0, cap = 0, c, i, j, row = cs->fdir == FD_ROW || cs->fdir == FD_ROW_REV;
    int gap_c = lay_len(&cs->cgap, cw), gap_r = lay_len(&cs->rgap, cw), top = y, x0 = cb_l;
    it = 0;
    flush_word();
    end_line(0);
    for (c = dn[e].first; c; c = dn[c].next) {           /* the items */
        struct cstyle *k;
        if (dn[c].type == DN_TEXT) {
            const char *s = dstr + dn[c].text;
            int q, ws = 1;
            for (q = 0; q < dn[c].tlen; q++) if (!is_space(s[q])) { ws = 0; break; }
            if (ws) continue;
        } else if (dn[c].type != DN_ELEM) continue;
        else {
            k = CS(c);
            if (!k || lay_hidden(c, k)) continue;
            if (k->position == P_ABSOLUTE || k->position == P_FIXED) {
                if (nabs < ABS_MAX) {
                    absq[nabs].e = c; absq[nabs].sx = x0; absq[nabs].sy = y;
                    absq[nabs].cb = k->position == P_FIXED || !npos ? 0 : pos_stack[npos - 1];
                    nabs++;
                }
                continue;
            }
        }
        if (n == cap) {
            struct fitem *nt;
            cap = cap ? cap * 2 : 16;
            nt = realloc(it, cap * sizeof *it);
            if (!nt) break;
            it = nt;
        }
        memset(&it[n], 0, sizeof it[n]);
        it[n].e = c;
        if (dn[c].type == DN_TEXT) {
            int word, cols = text_cols(dstr + dn[c].text, dn[c].tlen, &word, cs->ws);
            it[n].text = 1;
            it[n].mn = word * 8 * lay_scale(cs);
            it[n].mx = it[n].basis = cols * 8 * lay_scale(cs);
            it[n].shrink = 1;
        } else {
            struct cstyle *k = CS(c);
            int ref = row ? cw : cw;
            measure(c, &it[n].mn, &it[n].mx);
            it[n].ml = k->m[3].kind == L_AUTO ? 0 : lay_len(&k->m[3], ref);
            it[n].mr = k->m[1].kind == L_AUTO ? 0 : lay_len(&k->m[1], ref);
            it[n].grow = k->grow;
            it[n].shrink = k->shrink;
            it[n].order = k->order;
            if (row) {
                if (k->basis.kind == L_LEN) it[n].basis = css_resolve(&k->basis, cw) + (k->boxsz ? 0 : lay_hpad(k, cw));
                else if (k->w.kind == L_LEN) it[n].basis = css_resolve(&k->w, cw) + (k->boxsz ? 0 : lay_hpad(k, cw));
                else it[n].basis = it[n].mx;
                if (k->basis.kind == L_LEN && k->basis.px == 0 && !k->basis.pct && it[n].grow == 0) it[n].basis = it[n].mx;
                if (k->maxw.kind == L_LEN) { int m = css_resolve(&k->maxw, cw); if (it[n].basis > m) it[n].basis = m; }
                if (k->minw.kind == L_LEN) { int m = css_resolve(&k->minw, cw); if (it[n].mn < m) it[n].mn = m; if (it[n].basis < m) it[n].basis = m; }
                else if (k->overflow != OV_VISIBLE || k->w.kind == L_LEN) it[n].mn = 0;
                if (k->w.kind == L_LEN && it[n].mn > it[n].basis) it[n].mn = it[n].basis;
            }
        }
        n++;
    }
    if (!n) { free(it); return; }
    for (i = 1; i < n; i++) {                            /* order: */
        struct fitem t = it[i];
        for (j = i; j > 0 && fit_cmp_order(&t, &it[j - 1]) < 0; j--) it[j] = it[j - 1];
        it[j] = t;
    }
    if (cs->fdir == FD_ROW_REV || cs->fdir == FD_COL_REV)
        for (i = 0; i < n / 2; i++) { struct fitem t = it[i]; it[i] = it[n - 1 - i]; it[n - 1 - i] = t; }
    if (row) {
        int ls = 0;
        while (ls < n) {                                 /* each line */
            int le = ls, sum = 0, lineh = 0, free_, k;
            float tg = 0, ts = 0;
            int justify = cs->justify;
            if (cs->fdir == FD_ROW_REV) justify = justify == J_START ? J_END : justify == J_END ? J_START : justify;
            while (le < n) {
                int ow = it[le].basis + it[le].ml + it[le].mr;
                if (cs->fwrap && le > ls && sum + gap_c + ow > cw) break;
                sum += (le > ls ? gap_c : 0) + ow;
                le++;
            }
            for (k = ls; k < le; k++) { it[k].w = it[k].basis; tg += it[k].grow; ts += it[k].shrink * it[k].basis; }
            free_ = cw - sum;
            if (free_ > 0 && tg > 0) {
                int left = free_;
                for (k = ls; k < le; k++) if (it[k].grow > 0) {
                    int add = (int)(free_ * it[k].grow / tg);
                    if (!it[k].text && CS(it[k].e)->maxw.kind == L_LEN) {
                        int m = css_resolve(&CS(it[k].e)->maxw, cw);
                        if (it[k].w + add > m) add = m - it[k].w > 0 ? m - it[k].w : 0;
                    }
                    it[k].w += add;
                    left -= add;
                }
                free_ = left > 0 ? left : 0;
                if (free_ < 3) free_ = 0;
            } else if (free_ < 0 && ts > 0) {           /* too wide: shrunk (not past their words) */
                int over = -free_, pass;
                for (pass = 0; pass < 3 && over > 0; pass++) {
                    float tw = 0;
                    for (k = ls; k < le; k++) if (it[k].w > it[k].mn) tw += it[k].shrink * it[k].w;
                    if (tw <= 0) break;
                    {
                        int took = 0;
                        for (k = ls; k < le; k++) if (it[k].w > it[k].mn) {
                            int sub = (int)(over * it[k].shrink * it[k].w / tw + 0.5f);
                            if (it[k].w - sub < it[k].mn) sub = it[k].w - it[k].mn;
                            it[k].w -= sub;
                            took += sub;
                        }
                        over -= took;
                        if (!took) break;
                    }
                }
                free_ = 0;
            }
            {                                            /* margin: auto takes the room */
                int nauto = 0;
                for (k = ls; k < le; k++) if (!it[k].text) {
                    if (CS(it[k].e)->m[3].kind == L_AUTO) nauto++;
                    if (CS(it[k].e)->m[1].kind == L_AUTO) nauto++;
                }
                if (nauto && free_ > 0) {
                    int each = free_ / nauto;
                    for (k = ls; k < le; k++) if (!it[k].text) {
                        if (CS(it[k].e)->m[3].kind == L_AUTO) it[k].ml += each;
                        if (CS(it[k].e)->m[1].kind == L_AUTO) it[k].mr += each;
                    }
                    free_ = 0;
                }
            }
            {                                            /* placed: justify-content */
                int pos = x0, sp = gap_c, cnt = le - ls;
                if (free_ > 0) {
                    switch (justify) {
                    case J_END: pos += free_; break;
                    case J_CENTER: pos += free_ / 2; break;
                    case J_BETWEEN: if (cnt > 1) sp += free_ / (cnt - 1); else if (0) pos += free_; break;
                    case J_AROUND: pos += free_ / cnt / 2; sp += free_ / cnt; break;
                    case J_EVENLY: pos += free_ / (cnt + 1); sp += free_ / (cnt + 1); break;
                    }
                }
                for (k = ls; k < le; k++) {
                    int sty = y, w = it[k].w + it[k].ml + it[k].mr;
                    it[k].x = pos;
                    it[k].start = nitems;
                    x = pos;
                    line_start = nitems;
                    last_gap = 99;
                    if (it[k].text) {
                        int s_cbl = cb_l, s_cbr = cb_r;
                        cb_l = pos; cb_r = pos + it[k].w;
                        x = cb_l;
                        line_room();
                        lay_text(it[k].e, cs);
                        flush_word();
                        end_line(0);
                        cb_l = s_cbl; cb_r = s_cbr;
                        it[k].box.bg = -1; it[k].box.bgi = -1; it[k].box.br[0] = it[k].box.br[1] = it[k].box.br[2] = it[k].box.br[3] = -1;
                        it[k].box.top = sty; it[k].box.h = y - sty;
                    } else {
                        lay_fixed_w = 1;
                        lay_block(it[k].e, pos, pos + w, 0);
                        it[k].box = last_box;
                    }
                    it[k].h = y - sty;
                    it[k].end = nitems;
                    if (it[k].h > lineh) lineh = it[k].h;
                    y = sty;
                    pos += w + sp;
                }
                for (k = ls; k < le; k++) {              /* align-items / align-self */
                    int al = it[k].text ? cs->aitems : (CS(it[k].e)->aself != J_AUTO ? CS(it[k].e)->aself : cs->aitems);
                    int dy = 0;
                    if (al == J_CENTER) dy = (lineh - it[k].h) / 2;
                    else if (al == J_END) dy = lineh - it[k].h;
                    else if (al == J_STRETCH && !it[k].text && CS(it[k].e)->h.kind != L_LEN) {
                        int mt = lay_len(&CS(it[k].e)->m[0], cw), mb = lay_len(&CS(it[k].e)->m[2], cw);
                        box_stretch(&it[k].box, lineh - (mt > 0 ? mt : 0) - (mb > 0 ? mb : 0));
                        dn[it[k].e].bh = it[k].box.h;
                    }
                    if (dy > 0) shift_items(it[k].start, it[k].end, 0, dy);
                }
            }
            y += lineh;
            ls = le;
            if (ls < n) y += gap_r;
        }
    } else {                                             /* a column */
        int k, total_h = 0, start_y = y, free_h;
        int fixed_h = cs->h.kind == L_LEN && !cs->h.pct ? css_resolve(&cs->h, 0) - (cs->boxsz ? lay_len(&cs->p[0], cw) + lay_len(&cs->p[2], cw) : 0) : -1;
        if (cs->minh.kind == L_LEN && !cs->minh.pct && css_resolve(&cs->minh, 0) > fixed_h) fixed_h = css_resolve(&cs->minh, 0);
        for (k = 0; k < n; k++) {
            int sty = y, al = it[k].text ? cs->aitems : (CS(it[k].e)->aself != J_AUTO ? CS(it[k].e)->aself : cs->aitems);
            it[k].start = nitems;
            x = cb_l;
            line_start = nitems;
            last_gap = k ? 0 : 99;
            if (it[k].text) {
                lay_text(it[k].e, cs);
                flush_word();
                end_line(0);
            } else {
                int w = cw, ml = it[k].ml, mr = it[k].mr, bx = cb_l;
                struct cstyle *ks = CS(it[k].e);
                if (al != J_STRETCH && ks->w.kind != L_LEN) {
                    w = it[k].mx + ml + mr < cw ? it[k].mx + ml + mr : cw;
                    if (al == J_CENTER) bx = cb_l + (cw - w) / 2;
                    else if (al == J_END) bx = cb_l + cw - w;
                    lay_fixed_w = 1;
                    lay_block(it[k].e, bx, bx + w, 0);
                } else lay_block(it[k].e, cb_l, cb_l + cw, 0);
            }
            it[k].end = nitems;
            it[k].h = y - sty;
            total_h += it[k].h;
            if (k < n - 1) y += gap_r;
        }
        free_h = fixed_h > 0 ? fixed_h - (y - start_y) : 0;
        if (free_h > 0 && (cs->justify == J_CENTER || cs->justify == J_END || cs->justify == J_BETWEEN)) {
            int dy = cs->justify == J_CENTER ? free_h / 2 : cs->justify == J_END ? free_h : 0;
            if (cs->justify == J_BETWEEN && n > 1) {
                for (k = 1; k < n; k++) shift_items(it[k].start, it[k].end, 0, free_h * k / (n - 1));
            } else shift_items(it[0].start, it[n - 1].end, 0, dy);
            y += free_h;
        }
        (void)total_h;
    }
    x = cb_l;
    line_start = nitems;
    last_gap = 0;
    (void)top;
    free(it);
}

/* ================================================================
 * grid
 * ================================================================ */
#define GT_MAX 24
struct gtrack { int kind; float v, mn; };                 /* kind: 0 px, 1 %, 2 fr, 3 auto, 4 minmax(px, fr) */
static int grid_tracks(const char *t, struct gtrack *tr, int cw, int gap)
{
    int n = 0;
    while (t && *t && n < GT_MAX) {
        char tok[128];
        int k = 0, depth = 0;
        while (*t == ' ') t++;
        if (*t == '[') { while (*t && *t != ']') t++; if (*t) t++; continue; }
        if (starts_ci(t, "repeat(")) {
            const char *a = t + 7, *b;
            int count = 0, af = 0, i, m;
            struct gtrack sub[8];
            char inner[256];
            while (*a == ' ') a++;
            if (starts_ci(a, "auto-fill") || starts_ci(a, "auto-fit")) af = 1;
            else count = atoi(a);
            while (*a && *a != ',') a++;
            if (*a) a++;
            b = a;
            depth = 1;
            while (*b && depth) { if (*b == '(') depth++; else if (*b == ')') depth--; if (depth) b++; }
            k = b - a < 255 ? b - a : 255;
            memcpy(inner, a, k);
            inner[k] = 0;
            m = grid_tracks(inner, sub, cw, gap);
            if (af && m > 0) {                           /* as many as fit */
                int one = 0;
                for (i = 0; i < m; i++) one += sub[i].kind == 0 ? (int)sub[i].v : sub[i].kind == 4 ? (int)sub[i].mn : sub[i].kind == 1 ? (int)(sub[i].v * cw / 100) : 120;
                if (one < 1) one = 120;
                count = (cw + gap) / (one + gap);
                if (count < 1) count = 1;
            }
            if (count > GT_MAX) count = GT_MAX;
            for (i = 0; i < count * m && n < GT_MAX; i++) tr[n++] = sub[i % m];
            t = *b ? b + 1 : b;
            continue;
        }
        while (*t && (depth || *t != ' ') && k < 127) { if (*t == '(') depth++; else if (*t == ')') depth--; tok[k++] = *t++; }
        tok[k] = 0;
        if (!k) break;
        if (starts_ci(tok, "minmax(")) {
            struct clen l;
            char a1[64], a2[64];
            const char *p = tok + 7;
            int q = 0;
            while (*p && *p != ',' && q < 63) a1[q++] = *p++;
            a1[q] = 0;
            if (*p) p++;
            q = 0;
            while (*p == ' ') p++;
            while (*p && *p != ')' && q < 63) a2[q++] = *p++;
            a2[q] = 0;
            tr[n].kind = 4;
            tr[n].mn = css_len(a1, &l) && l.kind == L_LEN ? css_resolve(&l, cw) : 0;
            if (strstr_ci(a2, "fr")) tr[n].v = atoi(a2) > 0 ? (float)atoi(a2) : 1;
            else if (css_len(a2, &l) && l.kind == L_LEN) { tr[n].kind = 0; tr[n].v = css_resolve(&l, cw); if (tr[n].v < tr[n].mn) tr[n].v = tr[n].mn; }
            else { tr[n].kind = 4; tr[n].v = 1; }
            n++;
            continue;
        }
        if (strstr_ci(tok, "fr") && tok[0] >= '0' && tok[0] <= '9') {
            const char *p = tok;
            tr[n].kind = 2;
            tr[n].v = css_atof(&p);
            if (tr[n].v <= 0) tr[n].v = 1;
            n++;
            continue;
        }
        if (starts_ci(tok, "auto") || starts_ci(tok, "max-content") || starts_ci(tok, "min-content") || starts_ci(tok, "fit-content")) {
            tr[n].kind = 3; tr[n].v = 0; n++; continue;
        }
        {
            struct clen l;
            if (css_len(tok, &l) && l.kind == L_LEN) { tr[n].kind = 0; tr[n].v = css_resolve(&l, cw); n++; }
        }
    }
    return n;
}
/* "a a b" "c c b" -> the cells (rows x cols) of names */
static int grid_area_rect(const char *areas, const char *name, int *r0, int *c0, int *r1, int *c1)
{
    int row = 0, nl = strlen(name), found = 0;
    const char *p = areas;
    *r0 = *c0 = 1 << 20; *r1 = *c1 = -1;
    while (*p) {
        int col = 0;
        while (*p && *p != '"' && *p != '\'') p++;
        if (!*p) break;
        p++;
        while (*p && *p != '"' && *p != '\'') {
            const char *s;
            while (*p == ' ') p++;
            s = p;
            while (*p && *p != ' ' && *p != '"' && *p != '\'') p++;
            if (p > s) {
                if (p - s == nl && !memcmp(s, name, nl)) {
                    found = 1;
                    if (row < *r0) *r0 = row;
                    if (col < *c0) *c0 = col;
                    if (row > *r1) *r1 = row;
                    if (col > *c1) *c1 = col;
                }
                col++;
            }
        }
        if (*p) p++;
        row++;
    }
    return found;
}
static void lay_grid(int e, struct cstyle *cs, int cw)
{
    struct gtrack tr[GT_MAX];
    int nt, gap_c = cs->cgap.kind == L_LEN ? lay_len(&cs->cgap, cw) : 0, gap_r = cs->rgap.kind == L_LEN ? lay_len(&cs->rgap, cw) : 0;
    int colw[GT_MAX], colx[GT_MAX + 1], i, c, nitm = 0, cap = 0;
    struct gi { int e, r, c, rs, cs_, start, end, h; struct boxrec box; } *gi = 0;
    unsigned char *occ = 0;
    int rows_cap = 0, nrows = 0;
    flush_word();
    end_line(0);
    nt = grid_tracks(cs->grid_cols ? css_pool + cs->grid_cols : 0, tr, cw, gap_c);
    if (nt <= 0) { nt = 1; tr[0].kind = 2; tr[0].v = 1; }
    if (cs->grid_areas && !cs->grid_cols) {              /* (areas, no columns said: as many as the areas have) */
        const char *p = css_pool + cs->grid_areas;
        int cols = 0;
        while (*p && *p != '"' && *p != '\'') p++;
        if (*p) { p++; while (*p && *p != '"' && *p != '\'') { while (*p == ' ') p++; if (*p && *p != '"' && *p != '\'') { cols++; while (*p && *p != ' ' && *p != '"' && *p != '\'') p++; } } }
        if (cols > 1 && cols <= GT_MAX) { nt = cols; for (i = 0; i < nt; i++) { tr[i].kind = 2; tr[i].v = 1; } }
    }
    /* the items, placed */
    for (c = dn[e].first; c; c = dn[c].next) {
        struct cstyle *k;
        int r0 = -1, c0 = -1, rs = 1, cspan = 1;
        if (dn[c].type == DN_TEXT) {
            int q, ws = 1;
            for (q = 0; q < dn[c].tlen; q++) if (!is_space(dstr[dn[c].text + q])) { ws = 0; break; }
            if (ws) continue;
            k = cs;
        } else {
            if (dn[c].type != DN_ELEM) continue;
            k = CS(c);
            if (!k || lay_hidden(c, k)) continue;
            if (k->position == P_ABSOLUTE || k->position == P_FIXED) {
                if (nabs < ABS_MAX) {
                    absq[nabs].e = c; absq[nabs].sx = cb_l; absq[nabs].sy = y;
                    absq[nabs].cb = k->position == P_FIXED || !npos ? 0 : pos_stack[npos - 1];
                    nabs++;
                }
                continue;
            }
            if (k->grid_area && cs->grid_areas) {
                int a0, b0, a1, b1;
                if (grid_area_rect(css_pool + cs->grid_areas, css_pool + k->grid_area, &a0, &b0, &a1, &b1)) {
                    r0 = a0; c0 = b0; rs = a1 - a0 + 1; cspan = b1 - b0 + 1;
                }
            } else {
                if (k->gc_s >= 1000) cspan = k->gc_s - 1000;
                else if (k->gc_e >= 1000) cspan = k->gc_e - 1000;
                if (k->gc_s > 0 && k->gc_s < 1000) {
                    c0 = k->gc_s - 1;
                    if (k->gc_e > 0 && k->gc_e < 1000) cspan = k->gc_e - k->gc_s;
                    else if (k->gc_e < 0) cspan = nt + 1 + k->gc_e + 1 - k->gc_s;
                } else if (k->gc_s < 0) c0 = nt + 1 + k->gc_s - 1;
                if (k->gc_s == 1 && k->gc_e == -1) { c0 = 0; cspan = nt; }
                if (k->gr_s >= 1000) rs = k->gr_s - 1000;
                else if (k->gr_s > 0 && k->gr_s < 1000) { r0 = k->gr_s - 1; if (k->gr_e > k->gr_s && k->gr_e < 1000) rs = k->gr_e - k->gr_s; }
                if (k->gr_e >= 1000) rs = k->gr_e - 1000;
            }
        }
        if (cspan < 1) cspan = 1;
        if (cspan > nt) cspan = nt;
        if (c0 >= nt) c0 = nt - 1;
        if (c0 + cspan > nt) c0 = nt - cspan;
        if (rs < 1) rs = 1;
        if (rs > 50) rs = 50;
        if (nitm == cap) {
            void *ng;
            cap = cap ? cap * 2 : 32;
            ng = realloc(gi, cap * sizeof *gi);
            if (!ng) break;
            gi = ng;
        }
        gi[nitm].e = c; gi[nitm].r = r0; gi[nitm].c = c0; gi[nitm].rs = rs; gi[nitm].cs_ = cspan;
        nitm++;
    }
    {                                                    /* auto-placed: the next free cells */
        int cr = 0, cc = 0, k;
        for (k = 0; k < nitm; k++) {
            int r0 = gi[k].r, c0 = gi[k].c, rs = gi[k].rs, cspan = gi[k].cs_, ok, a, b;
            if (r0 < 0) {
                for (;;) {
                    int cc0 = c0 >= 0 ? c0 : cc;
                    if (cc0 + cspan > nt) { cr++; cc = 0; if (c0 >= 0) cc0 = c0; else cc0 = 0; }
                    ok = 1;
                    for (a = cr; a < cr + rs && ok; a++)
                        for (b = cc0; b < cc0 + cspan && ok; b++)
                            if (a < nrows && occ[a * GT_MAX + b]) ok = 0;
                    if (ok) { r0 = cr; c0 = cc0; break; }
                    if (c0 >= 0) cr++; else { cc++; if (cc + cspan > nt) { cr++; cc = 0; } }
                    if (cr > 2000) break;
                }
                cc = c0 + cspan;
                if (cc >= nt) { cc = 0; cr = r0 + 1; } else cr = r0;
            } else if (c0 < 0) c0 = 0;
            if (r0 < 0) r0 = 0;
            if (r0 + rs > rows_cap) {
                int nc = (r0 + rs) * 2 + 8;
                unsigned char *no = realloc(occ, nc * GT_MAX);
                if (!no) break;
                memset(no + rows_cap * GT_MAX, 0, (nc - rows_cap) * GT_MAX);
                occ = no;
                rows_cap = nc;
            }
            if (r0 + rs > nrows) nrows = r0 + rs;
            for (a = r0; a < r0 + rs; a++) for (b = c0; b < c0 + cspan; b++) occ[a * GT_MAX + b] = 1;
            gi[k].r = r0; gi[k].c = c0;
        }
    }
    {                                                    /* the columns' widths */
        int fixed = 0, frs = 0, k;
        float frsum = 0;
        int automax[GT_MAX];
        for (i = 0; i < nt; i++) automax[i] = 0;
        for (k = 0; k < nitm; k++) if (gi[k].cs_ == 1 && dn[gi[k].e].type == DN_ELEM) {
            int mn, mx;
            measure(gi[k].e, &mn, &mx);
            if (tr[gi[k].c].kind == 3 && mx > automax[gi[k].c]) automax[gi[k].c] = mx;
            if (tr[gi[k].c].kind == 4 && mn > tr[gi[k].c].mn && 0) tr[gi[k].c].mn = mn;
        }
        for (i = 0; i < nt; i++) {
            if (tr[i].kind == 0) colw[i] = (int)tr[i].v;
            else if (tr[i].kind == 1) colw[i] = (int)(tr[i].v * cw / 100);
            else if (tr[i].kind == 3) colw[i] = automax[i];
            else { colw[i] = tr[i].kind == 4 ? (int)tr[i].mn : 0; frsum += tr[i].v; frs++; }
            fixed += colw[i];
        }
        fixed += gap_c * (nt - 1);
        if (frs && frsum > 0) {
            int room = cw - fixed;
            for (i = 0; i < nt; i++) if (tr[i].kind == 2 || tr[i].kind == 4) {
                int add = room > 0 ? (int)(room * tr[i].v / frsum) : 0;
                if (tr[i].kind == 4) { int share = (int)((cw - (fixed - colw[i] * 0) - gap_c * 0) * 0); (void)share; }
                colw[i] += add;
            }
        } else if (fixed > cw) {                         /* (autos too wide: shared out) */
            int autos = 0;
            for (i = 0; i < nt; i++) if (tr[i].kind == 3) autos += colw[i];
            if (autos > 0) {
                int room = cw - (fixed - autos);
                for (i = 0; i < nt; i++) if (tr[i].kind == 3) colw[i] = room > 0 ? colw[i] * room / autos : 8;
            }
        } else if (fixed < cw) {                         /* (autos: the rest of the room) */
            int autos = 0;
            for (i = 0; i < nt; i++) if (tr[i].kind == 3) autos++;
            if (autos) for (i = 0; i < nt; i++) if (tr[i].kind == 3) colw[i] += (cw - fixed) / autos;
        }
        colx[0] = cb_l;
        for (i = 0; i < nt; i++) colx[i + 1] = colx[i] + colw[i] + gap_c;
        if (cs->justify == J_CENTER && colx[nt] - gap_c - cb_l < cw) {
            int d = (cw - (colx[nt] - gap_c - cb_l)) / 2;
            for (i = 0; i <= nt; i++) colx[i] += d;
        }
    }
    {                                                    /* row by row */
        int r, k;
        int *rowh = malloc((nrows + 1) * sizeof(int)), *rowy = malloc((nrows + 2) * sizeof(int));
        if (!rowh || !rowy) { free(rowh); free(rowy); free(gi); free(occ); return; }
        rowy[0] = y;
        for (r = 0; r < nrows; r++) {
            int top2 = rowy[r], hmax = 0;
            for (k = 0; k < nitm; k++) {
                int sty, x0g, x1g;
                if (gi[k].r != r) continue;
                x0g = colx[gi[k].c];
                x1g = colx[gi[k].c + gi[k].cs_] - gap_c;
                y = top2;
                sty = y;
                x = x0g;
                line_start = nitems;
                last_gap = 99;
                gi[k].start = nitems;
                if (dn[gi[k].e].type == DN_TEXT) {
                    int s_cbl = cb_l, s_cbr = cb_r;
                    cb_l = x0g; cb_r = x1g;
                    line_room();
                    lay_text(gi[k].e, cs);
                    flush_word();
                    end_line(0);
                    cb_l = s_cbl; cb_r = s_cbr;
                    gi[k].box.bg = gi[k].box.bgi = -1;
                    gi[k].box.br[0] = gi[k].box.br[1] = gi[k].box.br[2] = gi[k].box.br[3] = -1;
                    gi[k].box.top = sty; gi[k].box.h = y - sty;
                } else {
                    struct cstyle *ks = CS(gi[k].e);
                    int al = ks->aself != J_AUTO ? ks->aself : cs->aitems;
                    (void)al;
                    if (ks->w.kind != L_LEN || ks->w.pct) lay_fixed_w = 1;
                    lay_block(gi[k].e, x0g, x1g, 0);
                    gi[k].box = last_box;
                }
                gi[k].end = nitems;
                gi[k].h = y - sty;
                if (gi[k].rs == 1 && gi[k].h > hmax) hmax = gi[k].h;
            }
            rowh[r] = hmax;
            rowy[r + 1] = top2 + hmax + (r + 1 < nrows ? gap_r : 0);
            for (k = 0; k < nitm; k++) {                  /* stretched to the row (or centered in it) */
                if (gi[k].r != r || gi[k].rs != 1) continue;
                if (dn[gi[k].e].type == DN_ELEM) {
                    struct cstyle *ks = CS(gi[k].e);
                    int al = ks->aself != J_AUTO ? ks->aself : cs->aitems;
                    if (al == J_CENTER) shift_items(gi[k].start, gi[k].end, 0, (hmax - gi[k].h) / 2);
                    else if (al == J_END) shift_items(gi[k].start, gi[k].end, 0, hmax - gi[k].h);
                    else if (ks->h.kind != L_LEN) box_stretch(&gi[k].box, hmax);
                }
            }
        }
        for (k = 0; k < nitm; k++) if (gi[k].rs > 1) {   /* (spanning rows: as tall as they are) */
            int last = gi[k].r + gi[k].rs - 1;
            if (last < nrows) {
                int need = gi[k].h - (rowy[last + 1] - rowy[gi[k].r]);
                (void)need;
            }
        }
        y = rowy[nrows];
        if (nrows) {
            int bottom = rowy[nrows], k2;
            for (k2 = 0; k2 < nitm; k2++) {
                int b2 = rowy[gi[k2].r] + gi[k2].h;
                if (b2 > bottom) bottom = b2;
            }
            y = bottom;
        }
        free(rowh);
        free(rowy);
    }
    free(gi);
    free(occ);
    x = cb_l;
    line_start = nitems;
    last_gap = 0;
}

/* ================================================================
 * tables
 * ================================================================ */
#define TB_COLS 40
static int tb_cell_span(int c)
{
    const char *a = dom_attr(c, "colspan");
    int n = a ? atoi(a) : 1;
    return n < 1 ? 1 : n > TB_COLS ? TB_COLS : n;
}
/* the rows of a table, in order (thead, tbody, tfoot, tr) */
static int tb_rows(int e, int *rows, int max)
{
    int c, n = 0;
    for (c = dn[e].first; c && n < max; c = dn[c].next) {
        if (dn[c].type != DN_ELEM || !CS(c) || lay_hidden(c, CS(c))) continue;
        if (CS(c)->display == D_ROW) rows[n++] = c;
        else if (CS(c)->display == D_ROW_GROUP) {
            int r;
            for (r = dn[c].first; r && n < max; r = dn[r].next)
                if (dn[r].type == DN_ELEM && CS(r) && CS(r)->display == D_ROW && !lay_hidden(r, CS(r))) rows[n++] = r;
        }
    }
    return n;
}
static void lay_table(int e, struct cstyle *cs, int cw)
{
    static int rows[4096];
    int nr, r, c, ncol = 0, i, cmin[TB_COLS], cmax[TB_COLS], cspec[TB_COLS], colx[TB_COLS + 1], w[TB_COLS], tw;
    int border = dn[e].tag == T_table && dom_attr(e, "border") && atoi(dom_attr(e, "border")) > 0;
    int spacing = 0;
    flush_word();
    end_line(0);
    for (c = dn[e].first; c; c = dn[c].next)             /* <caption> first */
        if (dn[c].type == DN_ELEM && CS(c) && CS(c)->display == D_CAPTION && !lay_hidden(c, CS(c))) lay_block(c, cb_l, cb_r, 0);
    nr = tb_rows(e, rows, 4096);
    if (!nr) { lay_flow(e); return; }
    {                                                    /* (rows without cells - a layout of divs: as blocks) */
        int any = 0;
        for (r = 0; r < nr && !any; r++)
            for (c = dn[rows[r]].first; c; c = dn[c].next)
                if (dn[c].type == DN_ELEM && CS(c) && CS(c)->display == D_CELL) { any = 1; break; }
        if (!any) { for (r = 0; r < nr; r++) lay_block(rows[r], cb_l, cb_r, 0); return; }
    }
    for (i = 0; i < TB_COLS; i++) { cmin[i] = 0; cmax[i] = 0; cspec[i] = 0; }
    for (r = 0; r < nr; r++) {                           /* each column's widths */
        int ci = 0;
        for (c = dn[rows[r]].first; c; c = dn[c].next) {
            int sp, mn, mx;
            if (dn[c].type != DN_ELEM || !CS(c) || lay_hidden(c, CS(c))) continue;
            sp = tb_cell_span(c);
            if (ci >= TB_COLS) break;
            measure(c, &mn, &mx);
            if (sp == 1) {
                if (mn > cmin[ci]) cmin[ci] = mn;
                if (mx > cmax[ci]) cmax[ci] = mx;
                if (CS(c)->w.kind == L_LEN) {
                    int sw = CS(c)->w.pct ? -(int)CS(c)->w.pct : (int)CS(c)->w.px + lay_hpad(CS(c), 0);
                    if (sw > 0 && sw > cspec[ci]) cspec[ci] = sw;
                    if (sw < 0 && -sw > -cspec[ci] && cspec[ci] <= 0) cspec[ci] = sw;
                }
            }
            ci += sp;
        }
        if (ci > ncol) ncol = ci;
    }
    if (ncol > TB_COLS) ncol = TB_COLS;
    if (ncol < 1) ncol = 1;
    for (r = 0; r < nr; r++) {                           /* spans: what they need, shared */
        int ci = 0;
        for (c = dn[rows[r]].first; c; c = dn[c].next) {
            int sp, mn, mx, have = 0, havx = 0, k;
            if (dn[c].type != DN_ELEM || !CS(c) || lay_hidden(c, CS(c))) continue;
            sp = tb_cell_span(c);
            if (ci + sp > ncol) sp = ncol - ci;
            if (sp > 1) {
                measure(c, &mn, &mx);
                for (k = ci; k < ci + sp; k++) { have += cmin[k]; havx += cmax[k]; }
                if (mn > have) for (k = ci; k < ci + sp; k++) cmin[k] += (mn - have) / sp;
                if (mx > havx) for (k = ci; k < ci + sp; k++) cmax[k] += (mx - havx) / sp;
            }
            ci += sp > 0 ? sp : 1;
        }
    }
    {                                                    /* widths: the table's room shared */
        int smin = 0, smax = 0, full = cs->w.kind == L_LEN, target;
        for (i = 0; i < ncol; i++) {
            if (cspec[i] > 0) { cmax[i] = cspec[i] > cmin[i] ? cspec[i] : cmin[i]; }
            else if (cspec[i] < 0) { int p = -cspec[i] * cw / 100; if (p > cmin[i]) cmax[i] = p; }
            if (cmax[i] < cmin[i]) cmax[i] = cmin[i];
            smin += cmin[i];
            smax += cmax[i];
        }
        target = full ? cw : smax < cw ? smax : cw;
        for (i = 0; i < ncol; i++) {
            if (smax <= target) w[i] = smax ? cmax[i] + (full ? (target - smax) * cmax[i] / smax : 0) : target / ncol;
            else if (smin >= target) w[i] = smin ? cmin[i] * target / smin : target / ncol;
            else w[i] = cmin[i] + (cmax[i] - cmin[i]) * (target - smin) / (smax - smin);
            if (w[i] < 8) w[i] = 8;
        }
        tw = 0;
        for (i = 0; i < ncol; i++) tw += w[i];
        colx[0] = cb_l + (cs->talign == TA_CENTER && 0 ? (cw - tw) / 2 : 0);
        for (i = 0; i < ncol; i++) colx[i + 1] = colx[i] + w[i] + spacing;
    }
    if (border) {
        struct item *it = new_item(IT_RULE);
        if (it) { it->x = colx[0]; it->y = y; it->w = colx[ncol] - colx[0]; it->h = 1; it->color = C_RULE; }
        y++;
    }
    for (r = 0; r < nr; r++) {                           /* the rows */
        static struct { int start, end, h; struct boxrec box; int va; } cell[TB_COLS];
        int ci = 0, nc = 0, top = y, rowh = 0, rb = -1, k;
        struct cstyle *rs = CS(rows[r]);
        if (rs->has_bg) {
            struct item *it = new_item(IT_BOX);
            if (it) { it->x = colx[0]; it->y = top; it->w = colx[ncol] - colx[0]; it->color = rs->bg; rb = nitems - 1; }
        }
        for (c = dn[rows[r]].first; c && nc < TB_COLS; c = dn[c].next) {
            int sp;
            if (dn[c].type != DN_ELEM || !CS(c) || lay_hidden(c, CS(c))) continue;
            sp = tb_cell_span(c);
            if (ci >= ncol) break;
            if (ci + sp > ncol) sp = ncol - ci;
            y = top;
            x = colx[ci];
            line_start = nitems;
            last_gap = 99;
            cell[nc].start = nitems;
            lay_fixed_w = 1;
            lay_block(c, colx[ci], colx[ci + sp] - spacing, 0);
            cell[nc].box = last_box;
            cell[nc].end = nitems;
            cell[nc].h = y - top;
            cell[nc].va = CS(c)->valign;
            if (cell[nc].h > rowh) rowh = cell[nc].h;
            nc++;
            ci += sp;
        }
        for (k = 0; k < nc; k++) {                        /* each cell: the row's height, its content placed */
            int d = rowh - cell[k].h;
            box_stretch(&cell[k].box, rowh);
            if (d > 0 && cell[k].va == VA_MIDDLE) {
                int i2, from = cell[k].start;
                for (i2 = from; i2 < cell[k].end; i2++)
                    if (i2 != cell[k].box.bg && i2 != cell[k].box.bgi && i2 != cell[k].box.br[0] && i2 != cell[k].box.br[1] &&
                        i2 != cell[k].box.br[2] && i2 != cell[k].box.br[3]) { items[i2].y += d / 2; }
            } else if (d > 0 && cell[k].va == VA_BOTTOM) {
                int i2;
                for (i2 = cell[k].start; i2 < cell[k].end; i2++)
                    if (i2 != cell[k].box.bg && i2 != cell[k].box.br[0] && i2 != cell[k].box.br[1] && i2 != cell[k].box.br[2] && i2 != cell[k].box.br[3]) items[i2].y += d;
            }
        }
        if (rb >= 0) items[rb].h = rowh;
        y = top + rowh;
        if (border) {
            struct item *it;
            int j;
            for (j = 0; j <= ncol; j++) if ((it = new_item(IT_RULE))) { it->x = j < ncol ? colx[j] : colx[ncol] - 1; it->y = top; it->w = 1; it->h = rowh; it->color = C_RULE; }
            if ((it = new_item(IT_RULE))) { it->x = colx[0]; it->y = y; it->w = colx[ncol] - colx[0]; it->h = 1; it->color = C_RULE; }
            y++;
        }
        dn[rows[r]].bx = colx[0]; dn[rows[r]].by = top; dn[rows[r]].bw = colx[ncol] - colx[0]; dn[rows[r]].bh = rowh;
    }
    x = cb_l;
    line_start = nitems;
    last_gap = 0;
}

/* ================================================================
 * the page
 * ================================================================ */
/* the reader: the article's element (<article>, <main>, role=main) */
static int reader_root(void)
{
    int n, best = 0;
    for (n = dom_doc; n; n = dom_next_in(n, dom_doc)) {
        const char *r;
        if (dn[n].type != DN_ELEM) continue;
        if (dn[n].tag == T_article) return n;
        if (!best && (dn[n].tag == T_main || ((r = dom_attr(n, "role")) && !strcmp(r, "main")))) best = n;
    }
    return best;
}
static int reader_skip_el(int e)
{
    static const char *tags[] = { "nav", "footer", "aside", "form", "button", "select", "dialog", "iframe", "menu", 0 };
    static const char *words[] = { "nav", "menu", "footer", "sidebar", "comment", "share", "social", "related",
        "banner", "cookie", "subscribe", "promo", "breadcrumb", "advert", "sponsor", "popup", "modal", "newsletter",
        "widget", "toolbar", "rating", "recommend", "signup", "login", 0 };
    const char *cl = dom_attr(e, "class"), *id = dom_attr(e, "id"), *name = atom_name(dn[e].tag);
    int i;
    for (i = 0; tags[i]; i++) if (!strcmp(tags[i], name)) return 1;
    if (dn[e].tag != T_div && dn[e].tag != T_section && dn[e].tag != T_ul && dn[e].tag != T_ol && dn[e].tag != T_span) return 0;
    for (i = 0; words[i]; i++)
        if ((cl && strstr_ci(cl, words[i])) || (id && strstr_ci(id, words[i]))) return 1;
    return 0;
}
static void title_from_dom(void)
{
    int n;
    title[0] = 0;
    for (n = dom_head; n; n = dom_next_in(n, dom_doc))
        if (dn[n].type == DN_ELEM && dn[n].tag == T_title) {
            char *t = dom_text_of(n, 0);
            int k = 0, p = 0, l;
            if (!t) return;
            l = strlen(t);
            while (p < l && k < (int)sizeof title - 1) {
                char out[3];
                unsigned u = dom_u8(t, l, &p);
                int m = to_font(is_space(u) ? ' ' : u, out), i;
                for (i = 0; i < m && k < (int)sizeof title - 1; i++)
                    if (!(out[i] == ' ' && (!k || title[k - 1] == ' '))) title[k++] = out[i];
            }
            while (k && title[k - 1] == ' ') k--;
            title[k] = 0;
            free(t);
            return;
        }
}

static void layout_dom(void)
{
    int root = dom_html, i;
    struct cstyle *hs, *bs;
    mgen++;
    nfl = fl_base = 0;
    nabs = 0;
    npos = 0;
    nibg = 0;
    cur_layer = 0;
    lay_depth = 0;
    lay_img_depth = 0;
    css_reader = reader;
    css_page_bg = reader ? RGB(250, 246, 236) : C_PAGE;
    lay_img_bg = css_page_bg;
    for (i = 1; i < ndn; i++) dn[i].bx = dn[i].by = dn[i].bw = dn[i].bh = 0;     /* (not shown: no box) */
    lay_node = 0;
    css_compute_tree(dom_doc);
    hs = CS(dom_html);
    bs = CS(dom_body);
    if (!hs || !bs) return;
    if (reader) {                                         /* the reader: the article, in its colors */
        int r = reader_root(), n;
        for (n = dom_doc; n; n = dom_next_in(n, dom_doc))
            if (dn[n].type == DN_ELEM && CS(n) && reader_skip_el(n)) CS(n)->display = D_NONE;
        if (r) {
            for (n = dom_body; n; n = dom_next_in(n, dom_doc)) {          /* (what's not around the article: out) */
                if (dn[n].type != DN_ELEM || !CS(n) || n == dom_body) continue;
                if (!dom_within(r, n) && !dom_within(n, r)) CS(n)->display = D_NONE;
            }
        }
        for (n = dom_doc; n; n = dom_next_in(n, dom_doc))
            if (dn[n].type == DN_ELEM && CS(n)) { CS(n)->has_bg = 0; CS(n)->bg_url = 0; if (CS(n)->position >= P_ABSOLUTE) CS(n)->position = P_STATIC; CS(n)->flt = 0; }
        page_bg = css_page_bg;
        base_text = RGB(40, 36, 32);
        bs->m[1].kind = bs->m[3].kind = L_LEN;
        bs->m[1].px = bs->m[3].px = 96 - 18;
        bs->m[1].pct = bs->m[3].pct = 0;
    } else {
        page_bg = hs->has_bg ? hs->bg : bs->has_bg ? bs->bg : C_PAGE;
        if (!hs->has_bg && bs->has_bg) bs->has_bg = 0;   /* (the body's color is the page's) */
        hs->has_bg = 0;
        base_text = bs->color;
    }
    for (i = 0; i < nctrls; i++) ctrls[i].item = -1;
    lay_root = root;
    x = line_left = cb_l = 0;
    cb_r = line_right = W - SBW;
    y = 0;
    line_start = 0;
    pending_space = 0;
    last_gap = 0;
    talign_cur = 0;
    cur_link = -1;
    text_col = base_text;
    lay_block(root, 0, W - SBW, 0);
    flush_word();
    end_line(0);
    abs_flush(0, 0, 0, W - SBW, y > VIEW_H ? y : VIEW_H);
    for (i = 0; i < nabs; i++) absq[i].cb = 0;           /* (any left: on the page) */
    abs_flush(0, 0, 0, W - SBW, y > VIEW_H ? y : VIEW_H);
    {
        int bottom = y;
        for (i = 0; i < nitems; i++) if (items[i].kind != IT_NONE && items[i].y + items[i].h > bottom && items[i].y + items[i].h < y + 4000) bottom = items[i].y + items[i].h;
        y = bottom;
    }
}

#endif
