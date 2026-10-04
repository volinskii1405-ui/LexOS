/* js.h - LexOS Web's JavaScript: QuickJS (apps/qjs, MIT), and the page
 * for it. Most of what a page sees - document, window, the elements,
 * events, timers, fetch, XMLHttpRequest, localStorage, the observers -
 * is JavaScript itself (apps/jsdom.js, run before the page's own); it
 * stands on __lx, the functions here over dom.h's tree (nodes are
 * numbers, dn[]'s), css.h's selectors and styles, the layout's boxes
 * and the browser's fetching.
 *
 *   js_page_start()   a page's tree is new: a new JavaScript world for
 *                     it, its <script>s run (then DOMContentLoaded...)
 *   js_tick()         now and then: timers, animation frames, promises;
 *                     1 if the page changed (laid out again)
 *   js_event(...)     a click, a key: to the page's listeners first;
 *                     1 if one said preventDefault()
 *   js_stop()         the world gone (another page)
 *
 * A script runs 8 seconds at most (then it's stopped), the world gets
 * 48MB, and whatever goes wrong is in the console (Ctrl+K). */
#ifndef JS_H
#define JS_H

#define LX_STDIO_H                         /* (quickjs.h's headers: lexos.h has these) */
#define LX_STRING_H
#define LX_MATH_H
#ifndef NAN
#define NAN __builtin_nan("")
#endif
typedef struct lx_file FILE;
#include "qjs/quickjs.h"

extern void (*lx_out)(const char *s, int n);

static JSRuntime *jrt;
static JSContext *jcx;
static JSValue j_event_fn, j_tick_fn, j_start_fn;
static int js_enabled = 1;
static unsigned js_deadline, js_next_due, js_t0, js_last_relayout;
static int js_wants;                                    /* (mouse moves, scrolls: asked for) */
static int js_scripts, js_errors;
static char js_nav[URL_MAX];                            /* (where the page sent us: after it's back) */
static int js_nav_replace, js_submit_form = -1, js_hist_go;
static char js_push_url[URL_MAX];
#define JW_MOVE   1
#define JW_SCROLL 2
#define JW_KEYS   4

/* ---- the console: its last lines (F12) ---- */
#define JCON_N 48
#define JCON_W 200
static char jcon[JCON_N][JCON_W];
static unsigned char jcon_lvl[JCON_N];
static int jcon_n, jcon_at, show_console;
static void jcon_add(int lvl, const char *s, int n)
{
    char *d = jcon[jcon_at];
    int k = 0, p = 0;
    while (p < n && k < JCON_W - 4) {                    /* (UTF-8 -> the font; one line) */
        char f[3];
        unsigned u = dom_u8(s, n, &p);
        int m = to_font(u == '\n' || u == '\t' || u == '\r' ? ' ' : u, f), i;
        for (i = 0; i < m && k < JCON_W - 4; i++) d[k++] = f[i];
    }
    d[k] = 0;
    jcon_lvl[jcon_at] = lvl;
    jcon_at = (jcon_at + 1) % JCON_N;
    if (jcon_n < JCON_N) jcon_n++;
#ifdef LX_HOST
    lxh_log(lvl, s, n);
#endif
}
static void js_out(const char *s, int n) { jcon_add('E', s, n); }

/* the exception just thrown -> the console */
static void js_report(JSContext *cx)
{
    JSValue e = JS_GetException(cx), st;
    const char *m = JS_ToCString(cx, e);
    char line[400];
    copy(line, m ? m : "error", sizeof line);
    if (m) JS_FreeCString(cx, m);
    if (JS_IsObject(e)) {
        st = JS_GetPropertyStr(cx, e, "stack");
        if (JS_IsString(st)) {
            const char *s = JS_ToCString(cx, st);
            if (s) {
                int i;
                for (i = 0; s[i] == ' '; i++) ;
                append(line, " @ ", sizeof line);
                append(line, s + i, sizeof line);
                for (i = 0; line[i]; i++) if (line[i] == '\n') { line[i] = 0; break; }
                JS_FreeCString(cx, s);
            }
        }
        JS_FreeValue(cx, st);
    }
    JS_FreeValue(cx, e);
    js_errors++;
    jcon_add('E', line, strlen(line));
}
static void js_jobs(void)
{
    JSContext *c;
    int k;
    for (k = 0; k < 10000; k++) {
        int r = JS_ExecutePendingJob(jrt, &c);
        if (r == 0) break;
        if (r < 0) js_report(c);
    }
}
static int js_interrupt(JSRuntime *rt, void *op)
{
    (void)rt; (void)op;
    if ((int)(millis() - js_deadline) > 0) {
        jcon_add('E', "A script ran too long: stopped.", 31);
        return 1;
    }
    return 0;
}
static void js_budget(int ms) { js_deadline = millis() + ms; }

/* ---- argument helpers ---- */
#define JF(name) static JSValue name(JSContext *cx, JSValueConst this_val, int argc, JSValueConst *argv)
#define JARG(i) (argc > (i) ? argv[i] : JS_UNDEFINED)
static int jint(JSValueConst v) { int32_t r = 0; JS_ToInt32(jcx, &r, v); return r; }
static int jn(JSValueConst v) { int n = jint(v); return n > 0 && n < ndn ? n : 0; }
static int jel(JSValueConst v) { int n = jn(v); return n && dn[n].type == DN_ELEM ? n : 0; }
static JSValue jnum(int v) { return JS_NewInt32(jcx, v); }
static JSValue jstrn(const char *s, int n) { return JS_NewStringLen(jcx, s ? s : "", s ? n : 0); }
static JSValue jstr(const char *s) { return s ? JS_NewString(jcx, s) : JS_NULL; }

/* ---- the layout, kept up with the tree (what a script measures) ---- */
static void relayout_keep(void);
static void js_fresh(void) { if (dom_gen != js_laid_gen && !js_in_layout) relayout_keep(); }

/* ================================================================
 * the tree
 * ================================================================ */
#define DF_RAN 8                                         /* a <script> run (or never to be) */
JF(jx_parent) { return jnum(dn[jn(JARG(0))].parent); }
JF(jx_first)  { return jnum(dn[jn(JARG(0))].first); }
JF(jx_last)   { return jnum(dn[jn(JARG(0))].last); }
JF(jx_next)   { return jnum(dn[jn(JARG(0))].next); }
JF(jx_prev)   { return jnum(dn[jn(JARG(0))].prev); }
JF(jx_type)   { return jnum(dn[jn(JARG(0))].type); }
JF(jx_tag)    { return jnum(dn[jn(JARG(0))].tag); }
JF(jx_flags)  { return jnum(dn[jn(JARG(0))].flags); }
JF(jx_setflag) { int n = jn(JARG(0)); if (n) dn[n].flags |= jint(JARG(1)); return JS_UNDEFINED; }
JF(jx_atom)   { return jstr(atom_name(jint(JARG(0)))); }
JF(jx_doc)
{
    JSValue a = JS_NewArray(cx);
    JS_SetPropertyUint32(cx, a, 0, jnum(dom_doc));
    JS_SetPropertyUint32(cx, a, 1, jnum(dom_html));
    JS_SetPropertyUint32(cx, a, 2, jnum(dom_head));
    JS_SetPropertyUint32(cx, a, 3, jnum(dom_body));
    return a;
}
/* a text's (or comment's) words */
JF(jx_data)
{
    int n = jn(JARG(0));
    if (!n || (dn[n].type != DN_TEXT && dn[n].type != DN_COMMENT)) return jstrn("", 0);
    return jstrn(dstr + dn[n].text, dn[n].tlen);
}
JF(jx_setdata)
{
    int n = jn(JARG(0));
    size_t l;
    const char *s = JS_ToCStringLen(cx, &l, JARG(1));
    if (!s) return JS_EXCEPTION;
    if (n && (dn[n].type == DN_TEXT || dn[n].type == DN_COMMENT)) {
        int at = dom_str(s, l);
        dn[n].text = at;
        dn[n].tlen = l;
        dom_gen++;
    }
    JS_FreeCString(cx, s);
    return JS_UNDEFINED;
}
JF(jx_textof)
{
    int n = jn(JARG(0)), l;
    char *t;
    JSValue r;
    if (!n) return jstrn("", 0);
    if (dn[n].type == DN_TEXT || dn[n].type == DN_COMMENT) return jstrn(dstr + dn[n].text, dn[n].tlen);
    t = dom_text_of(n, &l);
    r = jstrn(t, t ? l : 0);
    free(t);
    return r;
}
static int jatom(JSValueConst v, int add)               /* an attribute's name -> its atom */
{
    size_t l;
    const char *s = JS_ToCStringLen(jcx, &l, v);
    int a;
    if (!s) return 0;
    a = atom_lc(s, l, add);
    JS_FreeCString(jcx, s);
    return a;
}
JF(jx_getattr)
{
    int e = jel(JARG(0)), a = e ? jatom(JARG(1), 0) : 0;
    return a ? jstr(dom_attr_a(e, a)) : JS_NULL;
}
static void js_ctrl_attr(int e, int a, const char *v);
JF(jx_setattr)
{
    int e = jel(JARG(0)), a = e ? jatom(JARG(1), 1) : 0;
    size_t l;
    const char *s;
    if (!a) return JS_UNDEFINED;
    s = JS_ToCStringLen(cx, &l, JARG(2));
    if (!s) return JS_EXCEPTION;
    {
        const char *old = dom_attr_a(e, a);
        if (!old || strlen(old) != l || memcmp(old, s, l)) dom_set_attr_a(e, a, s, l);
    }
    js_ctrl_attr(e, a, s);
    JS_FreeCString(cx, s);
    return JS_UNDEFINED;
}
JF(jx_delattr)
{
    int e = jel(JARG(0)), a = e ? jatom(JARG(1), 0) : 0;
    if (a && dom_attr_at(e, a) >= 0) { dom_del_attr(e, a); js_ctrl_attr(e, a, 0); }
    return JS_UNDEFINED;
}
JF(jx_attrs)                                             /* [name, value, name, value ...] */
{
    int e = jel(JARG(0)), i;
    JSValue a = JS_NewArray(cx);
    if (!e) return a;
    for (i = 0; i < dn[e].nattr; i++) {
        JS_SetPropertyUint32(cx, a, i * 2, jstr(atom_name(da[dn[e].attr + i].name)));
        JS_SetPropertyUint32(cx, a, i * 2 + 1, jstr(dstr + da[dn[e].attr + i].val));
    }
    return a;
}
JF(jx_create)
{
    int t = jatom(JARG(0), 1), e;
    if (!t) return jnum(0);
    e = dom_new(DN_ELEM, t);
    if (e) dn[e].flags |= DF_NEW;
    return jnum(e);
}
JF(jx_newtext)
{
    size_t l;
    const char *s = JS_ToCStringLen(cx, &l, JARG(0));
    int t, type = jint(JARG(1));
    if (!s) return JS_EXCEPTION;
    t = dom_new(type == DN_COMMENT ? DN_COMMENT : DN_TEXT, 0);
    if (t) { dn[t].text = dom_str(s, l); dn[t].tlen = l; }
    JS_FreeCString(cx, s);
    return jnum(t);
}
JF(jx_newfrag) { return jnum(dom_new(jint(JARG(0)) == DN_DOC ? DN_DOC : DN_FRAG, 0)); }
static void js_sel_refresh(int c);
static void js_changed_under(int p)                      /* (a <select>'s options, a <button>'s words) */
{
    for (; p; p = dn[p].parent)
        if (dn[p].type == DN_ELEM && dn[p].ctrl >= 0 && dn[p].ctrl < nctrls && ctrls[dn[p].ctrl].node == p) {
            js_sel_refresh(dn[p].ctrl);
            return;
        }
}
/* c into p, before ref (0: at the end); a fragment: what's in it */
JF(jx_insert)
{
    int p = jn(JARG(0)), c = jn(JARG(1)), ref = jn(JARG(2)), a;
    if (!p || !c || c == p || dom_within(c, p) || (ref && dn[ref].parent != p)) return jnum(0);
    if (dn[c].type == DN_FRAG) {
        while ((a = dn[c].first)) { dom_unlink(a); dom_insert(p, a, ref); }
    } else {
        if (dn[c].parent) dom_unlink(c);
        dom_insert(p, c, ref);
    }
    js_changed_under(p);
    return jnum(c);
}
JF(jx_remove)
{
    int c = jn(JARG(0)), p = c ? dn[c].parent : 0;
    if (p) { dom_unlink(c); js_changed_under(p); }
    return JS_UNDEFINED;
}
JF(jx_html)
{
    int n = jn(JARG(0));
    char *h;
    JSValue r;
    if (!n) return jstrn("", 0);
    h = dom_html_of(n, jint(JARG(1)));
    r = jstr(h ? h : "");
    free(h);
    return r;
}
/* HTML -> a new fragment with it (its <script>s never to run, unless run) */
JF(jx_parse)
{
    size_t l;
    const char *s = JS_ToCStringLen(cx, &l, JARG(0));
    int f, run = jint(JARG(1)), n;
    if (!s) return JS_EXCEPTION;
    f = dom_new(DN_FRAG, 0);
    if (f) dom_parse(s, l, CS_UTF8, f);
    JS_FreeCString(cx, s);
    if (f && !run)
        for (n = f; n; n = dom_next_in(n, f)) if (dn[n].type == DN_ELEM && dn[n].tag == T_script) dn[n].flags |= DF_RAN;
    return jnum(f);
}
static int js_clone(int n, int deep)
{
    int c, k, i;
    if (!n) return 0;
    c = dom_new(dn[n].type, dn[n].tag);
    if (!c) return 0;
    dn[c].flags = (dn[n].flags & (DF_SVG | DF_TPL | DF_RAN)) | DF_NEW;
    dn[c].text = dn[n].text;                             /* (strings are never changed in place) */
    dn[c].tlen = dn[n].tlen;
    for (i = 0; i < dn[n].nattr; i++) {
        int nm = da[dn[n].attr + i].name;
        char *v = dup_str(dstr + da[dn[n].attr + i].val);
        if (v) { dom_set_attr_a(c, nm, v, strlen(v)); free(v); }
    }
    if (deep) for (k = dn[n].first; k; k = dn[k].next) { int kc = js_clone(k, 1); if (kc) dom_insert(c, kc, 0); }
    return c;
}
JF(jx_clone) { return jnum(js_clone(jn(JARG(0)), JS_ToBool(cx, JARG(1)))); }
JF(jx_byid)
{
    const char *s = JS_ToCString(cx, JARG(0));
    int n;
    if (!s) return JS_EXCEPTION;
    n = dom_by_id(s);
    JS_FreeCString(cx, s);
    return jnum(n);
}
/* is a within b (or b itself) */
JF(jx_within) { int a = jn(JARG(0)), b = jn(JARG(1)); return JS_NewBool(cx, a && b && dom_within(a, b)); }

/* ---- selectors: compiled once (css.h's), kept by number ---- */
struct jsel { int first, n; };
static struct jsel *jsels;
static int njsels, jsels_cap;
JF(jx_sel)
{
    size_t l;
    const char *s = JS_ToCStringLen(cx, &l, JARG(0));
    int first, n;
    if (!s) return JS_EXCEPTION;
    if (!l || !css_sel_list(s, s + l, &first, &n) || !CSS_GROW(jsels, njsels, jsels_cap, 1)) { JS_FreeCString(cx, s); return jnum(-1); }
    JS_FreeCString(cx, s);
    jsels[njsels].first = first;
    jsels[njsels].n = n;
    return jnum(njsels++);
}
static int js_matches(int e, int h)
{
    int k;
    if (h < 0 || h >= njsels || !e || dn[e].type != DN_ELEM) return 0;
    for (k = 0; k < jsels[h].n; k++) if (css_match_sel(css_ci[jsels[h].first + k], e)) return 1;
    return 0;
}
JF(jx_match) { return JS_NewBool(cx, js_matches(jel(JARG(0)), jint(JARG(1)))); }
JF(jx_closest)
{
    int e = jel(JARG(0)), h = jint(JARG(1));
    for (; e && dn[e].type == DN_ELEM; e = dn[e].parent) if (js_matches(e, h)) return jnum(e);
    return jnum(0);
}
/* in root (not root itself): the first match, or all of them;
 * h -1: by tag (s), -2: by class names (s), -3: by name="s" */
static int js_class_all(int e, const char *want)
{
    const char *w = want;
    char one[128];
    while (*w) {
        int k = 0;
        while (*w == ' ' || *w == '\t' || *w == '\n') w++;
        if (!*w) break;
        while (*w && *w != ' ' && *w != '\t' && *w != '\n' && k < 127) one[k++] = *w++;
        one[k] = 0;
        if (!dom_has_class(e, one)) return 0;
    }
    return 1;
}
JF(jx_query)
{
    int root = jn(JARG(0)), h = jint(JARG(1)), all = jint(JARG(2)), n, k = 0, tag = 0, a_name = 0;
    const char *s = 0;
    JSValue arr = all ? JS_NewArray(cx) : JS_UNDEFINED;
    if (h < 0) {
        s = JS_ToCString(cx, JARG(3));
        if (!s) { JS_FreeValue(cx, arr); return JS_EXCEPTION; }
        if (h == -1 && strcmp(s, "*")) { tag = atom_lc(s, strlen(s), 0); if (!tag) goto done; }
        if (h == -3) a_name = atom_get("name", 4, 0);
    }
    if (!root) goto done;
    for (n = dom_next_in(root, root); n; n = dom_next_in(n, root)) {
        int ok;
        if (dn[n].type != DN_ELEM) continue;
        if (h >= 0) ok = js_matches(n, h);
        else if (h == -1) ok = !tag || dn[n].tag == tag;
        else if (h == -2) ok = js_class_all(n, s);
        else { const char *v = a_name ? dom_attr_a(n, a_name) : 0; ok = v && !strcmp(v, s); }
        if (!ok) continue;
        if (!all) { if (s) JS_FreeCString(cx, s); return jnum(n); }
        JS_SetPropertyUint32(cx, arr, k++, jnum(n));
    }
done:
    if (s) JS_FreeCString(cx, s);
    return all ? arr : jnum(0);
}

/* ================================================================
 * where things are, how they look
 * ================================================================ */
JF(jx_rect)                                              /* [x, y, w, h] on the page (0s: not shown) */
{
    int e = jn(JARG(0));
    JSValue a = JS_NewArray(cx);
    js_fresh();
    if (e == dom_doc) e = dom_html;
    JS_SetPropertyUint32(cx, a, 0, jnum(e ? dn[e].bx : 0));
    JS_SetPropertyUint32(cx, a, 1, jnum(e ? dn[e].by : 0));
    JS_SetPropertyUint32(cx, a, 2, jnum(e ? dn[e].bw : 0));
    JS_SetPropertyUint32(cx, a, 3, jnum(e ? dn[e].bh : 0));
    return a;
}
static void js_itoa(char *t, int v)
{
    char r[12];
    int k = 0, neg = v < 0, i = 0;
    unsigned u = neg ? -(unsigned)v : (unsigned)v;
    do { r[k++] = '0' + u % 10; u /= 10; } while (u);
    if (neg) t[i++] = '-';
    while (k) t[i++] = r[--k];
    t[i] = 0;
}
static void js_rgb(char *t, unsigned c, int a)
{
    char n[12];
    copy(t, a ? "rgb(" : "rgba(0, 0, 0, 0", 40);
    if (!a) { append(t, ")", 40); return; }
    js_itoa(n, c >> 16 & 255); append(t, n, 40); append(t, ", ", 40);
    js_itoa(n, c >> 8 & 255); append(t, n, 40); append(t, ", ", 40);
    js_itoa(n, c & 255); append(t, n, 40); append(t, ")", 40);
}
static void js_px(char *t, int v) { js_itoa(t, v); append(t, "px", 16); }
static void js_put(JSContext *cx, JSValue o, const char *k, const char *v) { JS_SetPropertyStr(cx, o, k, JS_NewString(cx, v)); }
/* getComputedStyle()'s: what css.h worked out (the ones it knows) */
JF(jx_cstyle)
{
    static const char *const disp[] = { "inline", "block", "none", "inline-block", "flex", "inline-flex", "grid", "inline-grid",
        "list-item", "table", "inline-table", "table-row", "table-cell", "table-row-group", "table-caption", "contents", "table-column" };
    static const char *const pos[] = { "static", "relative", "absolute", "fixed", "sticky" };
    static const char *const flt[] = { "none", "left", "right" };
    static const char *const ta[] = { "left", "center", "right", "justify" };
    static const char *const fd[] = { "row", "row-reverse", "column", "column-reverse" };
    static const char *const jc[] = { "flex-start", "flex-end", "center", "space-between", "space-around", "space-evenly", "stretch", "baseline", "normal" };
    static const char *const ov[] = { "visible", "hidden", "auto" };
    static const char *const ws[] = { "normal", "pre", "nowrap", "pre-wrap", "pre-line" };
    int e = jel(JARG(0)), i;
    struct cstyle *cs;
    JSValue o = JS_NewObject(cx);
    char t[48];
    js_fresh();
    cs = e ? (struct cstyle *)dn[e].cs : 0;
    if (!cs) { js_put(cx, o, "display", "none"); return o; }
    js_put(cx, o, "display", cs->display < 17 ? disp[cs->display] : "block");
    js_put(cx, o, "position", pos[cs->position % 5]);
    js_put(cx, o, "float", flt[cs->flt % 3]);
    js_put(cx, o, "visibility", cs->hidden ? "hidden" : "visible");
    js_rgb(t, cs->color, 1); js_put(cx, o, "color", t);
    js_rgb(t, cs->bg, cs->has_bg); js_put(cx, o, "background-color", t);
    js_px(t, cs->fsize); js_put(cx, o, "font-size", t);
    js_put(cx, o, "font-weight", cs->bold ? "700" : "400");
    js_put(cx, o, "font-style", cs->ital ? "italic" : "normal");
    js_put(cx, o, "font-family", "sans-serif");
    js_put(cx, o, "text-align", ta[cs->talign % 4]);
    js_put(cx, o, "text-decoration", cs->under ? "underline" : cs->strike ? "line-through" : "none");
    js_put(cx, o, "white-space", ws[cs->ws % 5]);
    js_put(cx, o, "overflow", ov[cs->overflow % 3]);
    js_put(cx, o, "flex-direction", fd[cs->fdir % 4]);
    js_put(cx, o, "justify-content", jc[cs->justify % 9]);
    js_put(cx, o, "align-items", jc[cs->aitems % 9]);
    js_put(cx, o, "box-sizing", cs->boxsz ? "border-box" : "content-box");
    js_itoa(t, (int)(cs->opacity * 100 + 0.5f));
    { char o2[16]; int v = (int)(cs->opacity * 100 + 0.5f); if (v >= 100) copy(o2, "1", 16); else { copy(o2, "0.", 16); if (v < 10) append(o2, "0", 16); append(o2, t, 16); } js_put(cx, o, "opacity", o2); }
    if (cs->zindex) { js_itoa(t, cs->zindex); js_put(cx, o, "z-index", t); } else js_put(cx, o, "z-index", "auto");
    js_px(t, dn[e].bw); js_put(cx, o, "width", t);
    js_px(t, dn[e].bh); js_put(cx, o, "height", t);
    {
        static const char *const side[] = { "top", "right", "bottom", "left" };
        for (i = 0; i < 4; i++) {
            char k[32];
            copy(k, "margin-", 32); append(k, side[i], 32); js_px(t, (int)cs->m[i].px); js_put(cx, o, k, t);
            copy(k, "padding-", 32); append(k, side[i], 32); js_px(t, (int)cs->p[i].px); js_put(cx, o, k, t);
            copy(k, "border-", 32); append(k, side[i], 32); append(k, "-width", 32); js_px(t, cs->bw[i] > 0 ? cs->bw[i] : 0); js_put(cx, o, k, t);
            copy(k, side[i], 32); if (cs->pos[i].kind == L_LEN) js_px(t, (int)cs->pos[i].px); else copy(t, "auto", 8); js_put(cx, o, k, t);
        }
    }
    js_put(cx, o, "line-height", "normal");
    js_put(cx, o, "cursor", "auto");
    js_put(cx, o, "pointer-events", "auto");
    js_put(cx, o, "transform", "none");
    js_put(cx, o, "transition-duration", "0s");
    js_put(cx, o, "animation-name", "none");
    return o;
}
/* elementFromPoint: the deepest element whose box is at x, y (the page's) */
JF(jx_hit)
{
    int x0 = jint(JARG(0)), y0 = jint(JARG(1)), i;
    js_fresh();
    for (i = nitems - 1; i >= 0; i--) {
        struct item *it = &items[i];
        if (it->kind == IT_NONE || !it->node) continue;
        if (x0 >= it->x && x0 < it->x + it->w && y0 >= it->y && y0 < it->y + it->h) {
            int n = it->node;
            while (n && dn[n].type != DN_ELEM) n = dn[n].parent;
            return jnum(n);
        }
    }
    return jnum(dom_body);
}

/* ================================================================
 * form fields: the ctrl (layout.h's) for an element
 * ================================================================ */
static void js_utf8_of_font(const char *v, char *out, int max)
{
    int k = 0;
    for (; *v && k < max - 5; v++) k += dom_utf8(font_uni((unsigned char)*v), out + k);
    out[k] = 0;
}
static int js_ctrl(int e) { return e && dn[e].type == DN_ELEM && (dn[e].tag == T_input || dn[e].tag == T_textarea || dn[e].tag == T_select || dn[e].tag == T_button) ? ctrl_for(e) : -1; }
/* <select>'s options, a <button>'s words: again (the tree changed) */
static void js_sel_refresh(int k)
{
    struct ctrl *c = &ctrls[k];
    int e = c->node, sel = c->sel;
    if (c->kind == CT_SELECT) {
        ctrl_options(c, e);
        if (sel < c->nopt) c->sel = sel;
    } else if (dn[e].tag == T_button) ctrl_btn_label(c, e);
}
/* an attribute set or gone (v 0): value=, checked= of a field nobody's typed into */
static void js_ctrl_attr(int e, int a, const char *v)
{
    int k;
    const char *nm = atom_name(a);
    if (dn[e].ctrl < 0 || dn[e].ctrl >= nctrls || ctrls[dn[e].ctrl].node != e) return;
    k = dn[e].ctrl;
    if (!strcmp(nm, "value") && !ctrls[k].edited && dn[e].tag != T_select) {
        if (dn[e].tag == T_button) js_sel_refresh(k);
        else ctrl_text_u8(&ctrls[k], v ? v : "");
    } else if (!strcmp(nm, "checked")) ctrls[k].checked = v != 0;
    else if (!strcmp(nm, "type")) ctrls[k].kind = ctrl_kind_of(e);
}
/* what: 0 value, 1 checked, 2 selectedIndex */
JF(jx_ctrlget)
{
    int e = jel(JARG(0)), what = jint(JARG(1)), k = js_ctrl(e);
    static char out[VAL_MAX * 3];
    struct ctrl *c;
    if (k < 0) return what ? jnum(what == 2 ? -1 : 0) : jstrn("", 0);
    c = &ctrls[k];
    if (what == 1) return JS_NewBool(cx, c->checked);
    if (what == 2) return jnum(c->kind == CT_SELECT && c->nopt ? c->sel : -1);
    if (c->kind == CT_SELECT) {
        const char *o = c->opts;
        int i, p = 0, n2 = 0;
        if (!o || !c->nopt) return jstrn("", 0);
        for (i = 0; i < c->sel; i++) { o += strlen(o) + 1; o += strlen(o) + 1; }
        o += strlen(o) + 1;
        for (i = 0; o[i] && n2 < (int)sizeof out - 5; ) { unsigned u = dom_cs_dec(o, strlen(o), &i, cs_mode); n2 += dom_utf8(u, out + n2); }
        (void)p;
        out[n2] = 0;
        return jstr(out);
    }
    if (dn[e].tag == T_button) { const char *v = dom_attr(e, "value"); return jstr(v ? v : ""); }
    if (c->edited && c->val) { js_utf8_of_font(c->val, out, sizeof out); return jstr(out); }
    if (c->raw) {
        int i = 0, n2 = 0, l = strlen(c->raw);
        while (i < l && n2 < (int)sizeof out - 5) { unsigned u = dom_cs_dec(c->raw, l, &i, cs_mode); n2 += dom_utf8(u, out + n2); }
        out[n2] = 0;
        return jstr(out);
    }
    return jstrn("", 0);
}
JF(jx_ctrlset)
{
    int e = jel(JARG(0)), what = jint(JARG(1)), k = js_ctrl(e), i;
    struct ctrl *c;
    if (k < 0) return JS_UNDEFINED;
    c = &ctrls[k];
    if (what == 1) {
        int on = JS_ToBool(cx, JARG(2));
        if (on && c->kind == CT_RADIO)
            for (i = 0; i < nctrls; i++)
                if (ctrls[i].kind == CT_RADIO && ctrls[i].form == c->form && !strcmp(ctrls[i].name, c->name)) ctrls[i].checked = 0;
        c->checked = on;
    } else if (what == 2) {
        int v = jint(JARG(2));
        if (c->kind == CT_SELECT && v >= 0 && v < c->nopt) c->sel = v;
    } else {
        const char *s = JS_ToCString(cx, JARG(2));
        if (!s) return JS_EXCEPTION;
        if (c->kind == CT_SELECT) {                      /* (the option with that value) */
            const char *o = c->opts;
            for (i = 0; o && i < c->nopt; i++) {
                const char *val = o + strlen(o) + 1;
                if (!strcmp(val, s)) { c->sel = i; break; }
                o = val + strlen(val) + 1;
            }
        } else if (c->kind != CT_SUBMIT && c->kind != CT_BUTTON && c->kind != CT_IMAGE) {
            ctrl_text_u8(c, s);
            c->edited = 0;
        }
        JS_FreeCString(cx, s);
    }
    dom_gen++;
    return JS_UNDEFINED;
}
JF(jx_focus)
{
    int e = jel(JARG(0)), k = js_ctrl(e);
    if (JS_ToBool(cx, JARG(1))) { if (k >= 0 && focus == k) focus = -1; }
    else if (k >= 0) focus = k;
    return JS_UNDEFINED;
}
JF(jx_active) { return jnum(focus >= 0 && focus < nctrls ? ctrls[focus].node : 0); }

/* ================================================================
 * the browser
 * ================================================================ */
JF(jx_url) { return jstr(url); }
JF(jx_base) { return jstr(base_url[0] ? base_url : url); }
JF(jx_resolve)
{
    static char out[URL_MAX];
    const char *h = JS_ToCString(cx, JARG(0)), *b = argc > 1 && !JS_IsUndefined(argv[1]) ? JS_ToCString(cx, argv[1]) : 0;
    JSValue r;
    if (!h) return JS_EXCEPTION;
    resolve(b ? b : base_url[0] ? base_url : url, h, out);
    r = jstr(out);
    JS_FreeCString(cx, h);
    if (b) JS_FreeCString(cx, b);
    return r;
}
JF(jx_nav)                                               /* (done when the script's back) */
{
    const char *s = JS_ToCString(cx, JARG(0));
    if (!s) return JS_EXCEPTION;
    resolve(base_url[0] ? base_url : url, s, js_nav);
    js_nav_replace = JS_ToBool(cx, JARG(1));
    JS_FreeCString(cx, s);
    return JS_UNDEFINED;
}
JF(jx_histgo) { js_hist_go = jint(JARG(0)); return JS_UNDEFINED; }
JF(jx_pushurl)                                           /* history.pushState(): the address shown */
{
    const char *s = JS_ToCString(cx, JARG(0));
    if (!s) return JS_EXCEPTION;
    resolve(url, s, js_push_url);
    JS_FreeCString(cx, s);
    if (js_push_url[0] && (is_http(js_push_url) == is_http(url))) {
        copy(url, js_push_url, URL_MAX);
        if (hpos >= 0 && hpos < HIST_MAX) copy(hist[hpos], url, URL_MAX);
    }
    return JS_UNDEFINED;
}
JF(jx_submit) { int f = jel(JARG(0)); if (f) js_submit_form = f; return JS_UNDEFINED; }
JF(jx_title)
{
    const char *t = JS_ToCString(cx, JARG(0));
    int k = 0, p = 0, l;
    if (!t) return JS_EXCEPTION;
    l = strlen(t);
    while (p < l && k < (int)sizeof title - 1) {
        char out[3];
        unsigned u = dom_u8(t, l, &p);
        int m = to_font(is_space(u) ? ' ' : u, out), i;
        for (i = 0; i < m && k < (int)sizeof title - 1; i++) if (!(out[i] == ' ' && (!k || title[k - 1] == ' '))) title[k++] = out[i];
    }
    title[k] = 0;
    JS_FreeCString(cx, t);
    return JS_UNDEFINED;
}
JF(jx_log)
{
    size_t l;
    const char *s = JS_ToCStringLen(cx, &l, JARG(1));
    if (!s) return JS_EXCEPTION;
    jcon_add(jint(JARG(0)), s, l);
    if (jint(JARG(0)) == 'E') js_errors++;
    JS_FreeCString(cx, s);
    return JS_UNDEFINED;
}
JF(jx_alert)
{
    const char *s = JS_ToCString(cx, JARG(0));
    char t[200];
    if (!s) return JS_EXCEPTION;
    font_text(s, t, sizeof t);
    notify(t);
    jcon_add('A', s, strlen(s));
    JS_FreeCString(cx, s);
    return JS_UNDEFINED;
}
JF(jx_view)                                              /* [width, height, scroll, page height] */
{
    JSValue a = JS_NewArray(cx);
    JS_SetPropertyUint32(cx, a, 0, jnum(W - SBW));
    JS_SetPropertyUint32(cx, a, 1, jnum(VIEW_H));
    JS_SetPropertyUint32(cx, a, 2, jnum(scroll));
    JS_SetPropertyUint32(cx, a, 3, jnum(doc_h));
    return a;
}
JF(jx_scroll) { js_fresh(); scroll = jint(JARG(0)); clamp_scroll(); return jnum(scroll); }
JF(jx_now) { return JS_NewFloat64(cx, (double)(unsigned)(millis() - js_t0)); }
JF(jx_due) { unsigned t = js_t0 + (unsigned)jint(JARG(0)); if ((int)(t - js_next_due) < 0) js_next_due = t; return JS_UNDEFINED; }
JF(jx_want) { js_wants = jint(JARG(0)); return JS_UNDEFINED; }
JF(jx_cookie)
{
    char host[URL_MAX], cks[4096];
    const char *p = url + (is_https(url) ? 8 : 7), *path;
    int n = 0;
    if (!is_http(url)) return jstrn("", 0);
    while (*p && *p != '/' && *p != ':' && *p != '?' && n < URL_MAX - 1) host[n++] = *p++;
    host[n] = 0;
    while (*p && *p != '/') p++;
    path = *p ? p : "/";
    ck_header(host, path, is_https(url), cks, sizeof cks);
    if (cks[0]) {                                        /* "Cookie: a=b\r\n" -> "a=b" */
        int l = strlen(cks);
        while (l && (cks[l - 1] == '\r' || cks[l - 1] == '\n')) cks[--l] = 0;
        return jstr(cks + 8);
    }
    return jstrn("", 0);
}
JF(jx_setcookie)
{
    const char *s = JS_ToCString(cx, JARG(0));
    const char *p = url + (is_https(url) ? 8 : 7);
    int n = 0;
    if (!s) return JS_EXCEPTION;
    if (is_http(url)) {
        while (*p && *p != '/' && *p != ':' && *p != '?' && n < URL_MAX - 1) cur_host[n++] = *p++;
        cur_host[n] = 0;
        ck_set(s);
        ck_save();
    }
    JS_FreeCString(cx, s);
    return JS_UNDEFINED;
}

/* ---- fetching: what a script asks for (in turn, while it waits) ---- */
static int js_get(const char *where, unsigned char **out, int *code, char *ctype, char *final)
{
    int save_tg = tg, n;
    static char pi_copy[sizeof pi];
    memcpy(pi_copy, &pi, sizeof pi);
    tg = T_BUF; tbuf = 0; tcap = 0; tlen = 0; tbuf_auto = 1;
    n = net_get(where, final);
    *code = n >= 0 ? (pi.code ? pi.code : 200) : 0;
    copy(ctype, pi.ctype, 128);
    tg = save_tg; tbuf_auto = 0;
    memcpy(&pi, pi_copy, sizeof pi);
    *out = tbuf;
    tbuf = 0;
    if (n < 0) { free(*out); *out = 0; return n; }
    return tlen;
}
/* (method, url, "Header: v\r\n"..., body, binary?) -> [status, text or ArrayBuffer, final url, content type] */
JF(jx_http)
{
    const char *m = JS_ToCString(cx, JARG(0)), *u = JS_ToCString(cx, JARG(1)), *h = JS_ToCString(cx, JARG(2));
    size_t bl = 0;
    const char *b = JS_IsString(JARG(3)) ? JS_ToCStringLen(cx, &bl, JARG(3)) : 0;
    char w[URL_MAX], final[URL_MAX], ctype[128];
    unsigned char *out = 0;
    int code = 0, n;
    JSValue a = JS_NewArray(cx);
    if (!m || !u || !h) goto done;
    resolve(base_url[0] ? base_url : url, u, w);
    copy(final, w, URL_MAX);
    ctype[0] = 0;
    copy(status, "Script fetching ", sizeof status); append(status, w, sizeof status);
    draw_status(); gfx_blit(frame);
    js_req_method = m; js_req_hdrs = h; js_req_body = b; js_req_blen = bl;
    n = js_get(w, &out, &code, ctype, final);
    js_req_method = js_req_hdrs = js_req_body = 0; js_req_blen = 0;
    status[0] = 0;
    JS_SetPropertyUint32(cx, a, 0, jnum(code));
    if (jint(JARG(4))) JS_SetPropertyUint32(cx, a, 1, JS_NewArrayBufferCopy(cx, out ? out : (unsigned char *)"", n > 0 ? n : 0));
    else JS_SetPropertyUint32(cx, a, 1, jstrn((const char *)out, n > 0 ? n : 0));
    JS_SetPropertyUint32(cx, a, 2, jstr(final));
    JS_SetPropertyUint32(cx, a, 3, jstr(ctype));
    free(out);
done:
    if (m) JS_FreeCString(cx, m);
    if (u) JS_FreeCString(cx, u);
    if (h) JS_FreeCString(cx, h);
    if (b) JS_FreeCString(cx, b);
    js_budget(8000);                                     /* (the wait isn't the script's) */
    return a;
}
/* a <script src>, a <link rel=stylesheet>'s file: its text (null: none) */
static char *js_load(const char *u, int *len)
{
    unsigned char *b = 0;
    int n;
    char *r;
    int code = 200;
    copy(status, "Loading script ", sizeof status); append(status, u, sizeof status);
    draw_status(); gfx_blit(frame);
    if (!is_http(u)) n = load_auto(u, &b);
    else if (cache_reload || (n = cache_get(u, &b)) <= 0) {          /* (only what came whole: an error page is no script) */
        char ctype[128], final[URL_MAX];
        n = js_get(u, &b, &code, ctype, final);
        if (n > 0 && b && code >= 200 && code < 300) cache_put(u, b, n);
    }
    status[0] = 0;
    js_budget(8000);
    if (n < 0 || !b || code < 200 || code >= 300) { free(b); return 0; }
    r = realloc(b, n + 1);
    if (!r) { free(b); return 0; }
    r[n] = 0;
    *len = n;
    return r;
}
JF(jx_load)
{
    const char *u = JS_ToCString(cx, JARG(0));
    char w[URL_MAX], *t;
    int n = 0;
    JSValue r;
    if (!u) return JS_EXCEPTION;
    resolve(base_url[0] ? base_url : url, u, w);
    JS_FreeCString(cx, u);
    t = js_load(w, &n);
    r = t ? jstrn(t, n) : JS_NULL;
    free(t);
    return r;
}
/* run code (a classic script; module: as a module) */
static int js_run(const char *code, int n, const char *name, int module)
{
    JSValue v;
    js_budget(8000);
    v = JS_Eval(jcx, code, n, name, module ? JS_EVAL_TYPE_MODULE : JS_EVAL_TYPE_GLOBAL);
    js_scripts++;
    if (JS_IsException(v)) { js_report(jcx); return 0; }
    if (module && JS_IsObject(v)) {                      /* (a promise: its error, if it ends with one) */
        js_jobs();
        if (JS_PromiseState(jcx, v) == JS_PROMISE_REJECTED) {
            JSValue e = JS_PromiseResult(jcx, v);
            JS_Throw(jcx, e);
            js_report(jcx);
        }
    }
    JS_FreeValue(jcx, v);
    return 1;
}
JF(jx_run)
{
    size_t l;
    const char *code = JS_ToCStringLen(cx, &l, JARG(0)), *name = JS_ToCString(cx, JARG(1));
    int ok;
    unsigned saved = js_deadline;
    if (!code || !name) { if (code) JS_FreeCString(cx, code); if (name) JS_FreeCString(cx, name); return JS_EXCEPTION; }
    ok = js_run(code, l, name, jint(JARG(2)));
    js_deadline = saved;
    JS_FreeCString(cx, code);
    JS_FreeCString(cx, name);
    return JS_NewBool(cx, ok);
}
/* CSS a script made (<style>, insertRule, <link> it added): on top of the rest */
static int js_sheet_seq = 100000;
JF(jx_addcss)
{
    size_t l;
    const char *s = JS_ToCStringLen(cx, &l, JARG(0));
    const char *href = JS_IsString(JARG(1)) ? JS_ToCString(cx, JARG(1)) : 0;
    if (!s) return JS_EXCEPTION;
    if (href) {
        char w[URL_MAX];
        resolve(base_url[0] ? base_url : url, href, w);
        load_style(w, js_sheet_seq++, base_url[0] ? base_url : url);
        JS_FreeCString(cx, href);
    } else if (l) {
        css_begin_sheet(js_sheet_seq++);
        css_url_fix = resolve;
        copy(css_base, base_url[0] ? base_url : url, sizeof css_base);
        {
            size_t i;
            for (i = 0; i < l; i++) css_feed((unsigned char)s[i]);
        }
        css_end();
        css_base[0] = 0;
    }
    JS_FreeCString(cx, s);
    dom_gen++;
    js_budget(8000);
    return JS_UNDEFINED;
}
/* localStorage: one file per site, /TMP/WEB/LS<hash>, "key\0value\0"... */
static void js_ls_name(char *nm)
{
    char host[URL_MAX];
    const char *p = url + (is_https(url) ? 8 : is_http(url) ? 7 : 0);
    unsigned h = 2166136261u;
    int n = 0, i;
    while (*p && *p != '/' && *p != '?' && n < URL_MAX - 1) host[n++] = *p++;
    host[n] = 0;
    for (i = 0; host[i]; i++) h = (h ^ (unsigned char)lower(host[i])) * 16777619u;
    copy(nm, "/TMP/WEB/LS000000", 20);
    for (i = 0; i < 6; i++) nm[11 + i] = "0123456789ABCDEF"[(h >> (i * 4)) & 15];
}
JF(jx_lsload)
{
    char nm[24];
    int fd, n;
    char *b;
    JSValue r;
    js_ls_name(nm);
    if ((fd = open(nm, O_READ)) < 0) return JS_NULL;
    n = fsize(fd);
    b = n > 0 && n < 4 * 1024 * 1024 ? malloc(n) : 0;
    if (!b || read(fd, b, n) != n) { close(fd); free(b); return JS_NULL; }
    close(fd);
    r = jstrn(b, n);
    free(b);
    return r;
}
JF(jx_lssave)
{
    char nm[24];
    size_t l;
    const char *s = JS_ToCStringLen(cx, &l, JARG(0));
    int fd;
    if (!s) return JS_EXCEPTION;
    js_ls_name(nm);
    mkdir("/TMP/WEB");
    if ((fd = open(nm, O_WRITE)) >= 0) { fwrite(fd, s, l); close(fd); }
    JS_FreeCString(cx, s);
    return JS_UNDEFINED;
}
JF(jx_clip)
{
    size_t l;
    const char *s = JS_ToCStringLen(cx, &l, JARG(0));
    if (!s) return JS_EXCEPTION;
    {
        char *t = malloc(l + 1);
        if (t) { font_text(s, t, l + 1); clip_text_set(t, strlen(t)); free(t); }
    }
    JS_FreeCString(cx, s);
    return JS_UNDEFINED;
}
/* a node's children (elements only: 1) */
JF(jx_kids)
{
    int n = jn(JARG(0)), el = jint(JARG(1)), c, k = 0;
    JSValue a = JS_NewArray(cx);
    if (n) for (c = dn[n].first; c; c = dn[c].next) if (!el || dn[c].type == DN_ELEM) JS_SetPropertyUint32(cx, a, k++, jnum(c));
    return a;
}
JF(jx_empty)
{
    int n = jn(JARG(0)), c, any = 0;
    while (n && (c = dn[n].first)) { dom_unlink(c); any = 1; }
    if (any) js_changed_under(n);
    return JS_UNDEFINED;
}
/* in root (and root): the elements a script must know of when they come
 * into the page - <script>, <style>, <link>, <iframe>, <img>, custom ones (a-b) */
JF(jx_scanels)
{
    int root = jn(JARG(0)), n, k = 0;
    JSValue a = JS_NewArray(cx);
    for (n = root; n; n = dom_next_in(n, root)) {
        int t;
        if (dn[n].type != DN_ELEM) continue;
        t = dn[n].tag;
        if (t == T_script || t == T_style || t == T_link || t == T_iframe || t == T_img || t >= T_KNOWN) {
            if (t >= T_KNOWN) { const char *nm = atom_name(t); while (*nm && *nm != '-') nm++; if (!*nm) continue; }
            JS_SetPropertyUint32(cx, a, k++, jnum(n));
        }
    }
    return a;
}
JF(jx_gen) { if (argc) dom_gen = jint(argv[0]); return jnum(dom_gen); }

/* ---- modules: import "./x.js" - from where the importer is ---- */
static char *js_mod_name(JSContext *cx, const char *base, const char *name, void *op)
{
    char out[URL_MAX];
    (void)op;
    resolve(base && *base ? base : base_url[0] ? base_url : url, name, out);
    return js_strdup(cx, out);
}
static JSModuleDef *js_mod_load(JSContext *cx, const char *name, void *op)
{
    char *t;
    int n = 0;
    JSValue f;
    JSModuleDef *m;
    (void)op;
    t = js_load(name, &n);
    if (!t) { JS_ThrowReferenceError(cx, "could not load module '%s'", name); return 0; }
    f = JS_Eval(cx, t, n, name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    free(t);
    if (JS_IsException(f)) return 0;
    m = JS_VALUE_GET_PTR(f);
    JS_FreeValue(cx, f);
    return m;
}

static const JSCFunctionListEntry jx_funcs[] = {
    JS_CFUNC_DEF("parent", 1, jx_parent), JS_CFUNC_DEF("first", 1, jx_first), JS_CFUNC_DEF("last", 1, jx_last),
    JS_CFUNC_DEF("next", 1, jx_next), JS_CFUNC_DEF("prev", 1, jx_prev), JS_CFUNC_DEF("type", 1, jx_type),
    JS_CFUNC_DEF("tag", 1, jx_tag), JS_CFUNC_DEF("flags", 1, jx_flags), JS_CFUNC_DEF("setflag", 2, jx_setflag),
    JS_CFUNC_DEF("atom", 1, jx_atom), JS_CFUNC_DEF("doc", 0, jx_doc), JS_CFUNC_DEF("data", 1, jx_data),
    JS_CFUNC_DEF("setdata", 2, jx_setdata), JS_CFUNC_DEF("textof", 1, jx_textof), JS_CFUNC_DEF("getattr", 2, jx_getattr),
    JS_CFUNC_DEF("setattr", 3, jx_setattr), JS_CFUNC_DEF("delattr", 2, jx_delattr), JS_CFUNC_DEF("attrs", 1, jx_attrs),
    JS_CFUNC_DEF("create", 1, jx_create), JS_CFUNC_DEF("newtext", 2, jx_newtext), JS_CFUNC_DEF("newfrag", 1, jx_newfrag),
    JS_CFUNC_DEF("insert", 3, jx_insert), JS_CFUNC_DEF("remove", 1, jx_remove), JS_CFUNC_DEF("html", 2, jx_html),
    JS_CFUNC_DEF("parse", 2, jx_parse), JS_CFUNC_DEF("clone", 2, jx_clone), JS_CFUNC_DEF("byid", 1, jx_byid),
    JS_CFUNC_DEF("within", 2, jx_within), JS_CFUNC_DEF("sel", 1, jx_sel), JS_CFUNC_DEF("match", 2, jx_match),
    JS_CFUNC_DEF("closest", 2, jx_closest), JS_CFUNC_DEF("query", 4, jx_query), JS_CFUNC_DEF("rect", 1, jx_rect),
    JS_CFUNC_DEF("cstyle", 1, jx_cstyle), JS_CFUNC_DEF("hit", 2, jx_hit), JS_CFUNC_DEF("ctrlget", 2, jx_ctrlget),
    JS_CFUNC_DEF("ctrlset", 3, jx_ctrlset), JS_CFUNC_DEF("focus", 2, jx_focus), JS_CFUNC_DEF("active", 0, jx_active),
    JS_CFUNC_DEF("url", 0, jx_url), JS_CFUNC_DEF("base", 0, jx_base), JS_CFUNC_DEF("resolve", 2, jx_resolve),
    JS_CFUNC_DEF("nav", 2, jx_nav), JS_CFUNC_DEF("histgo", 1, jx_histgo), JS_CFUNC_DEF("pushurl", 1, jx_pushurl),
    JS_CFUNC_DEF("submit", 1, jx_submit), JS_CFUNC_DEF("title", 1, jx_title), JS_CFUNC_DEF("log", 2, jx_log),
    JS_CFUNC_DEF("alert", 1, jx_alert), JS_CFUNC_DEF("view", 0, jx_view), JS_CFUNC_DEF("scroll", 1, jx_scroll),
    JS_CFUNC_DEF("now", 0, jx_now), JS_CFUNC_DEF("due", 1, jx_due), JS_CFUNC_DEF("want", 1, jx_want),
    JS_CFUNC_DEF("cookie", 0, jx_cookie), JS_CFUNC_DEF("setcookie", 1, jx_setcookie), JS_CFUNC_DEF("http", 5, jx_http),
    JS_CFUNC_DEF("load", 1, jx_load), JS_CFUNC_DEF("run", 3, jx_run), JS_CFUNC_DEF("addcss", 2, jx_addcss),
    JS_CFUNC_DEF("lsload", 0, jx_lsload), JS_CFUNC_DEF("lssave", 1, jx_lssave), JS_CFUNC_DEF("clip", 1, jx_clip),
    JS_CFUNC_DEF("gen", 1, jx_gen), JS_CFUNC_DEF("kids", 2, jx_kids), JS_CFUNC_DEF("empty", 1, jx_empty),
    JS_CFUNC_DEF("scan", 1, jx_scanels),
};

/* ================================================================
 * the world: made, fed the page, ticked, ended
 * ================================================================ */
extern const char js_prelude[];
__asm__(".section .rodata\n"
        ".global js_prelude\n"
        "js_prelude:\n"
        ".incbin \"apps/jsdom.js\"\n"
        ".byte 0\n"
        ".previous\n");

static void js_stop(void)
{
    if (!jrt) return;
    JS_FreeValue(jcx, j_event_fn);
    JS_FreeValue(jcx, j_tick_fn);
    JS_FreeValue(jcx, j_start_fn);
    JS_FreeContext(jcx);
    JS_FreeRuntime(jrt);
    jrt = 0;
    jcx = 0;
    njsels = 0;
    js_wants = 0;
}
static void relayout_keep(void);
static void js_page_start(void)
{
    JSValue g, lx, v;
    js_stop();
    js_scripts = js_errors = 0;
    js_nav[0] = 0; js_hist_go = 0; js_submit_form = -1;
    if (!js_enabled || pi.kind != PK_HTML || view_source || starts_ci(url, "about:")) return;
    {                                                    /* (no <script>: no world needed) */
        int n, any = 0;
        for (n = dom_doc; n && !any; n = dom_next_in(n, dom_doc))
            if (dn[n].type == DN_ELEM && (dn[n].tag == T_script || (dn[n].tag != T_body && dn[n].nattr && dom_attr(n, "onclick")))) any = 1;
        if (!any) {
            int a = atom_get("onload", 6, 0);
            if (!a || !dom_attr_a(dom_body, a)) return;
        }
    }
    lx_out = js_out;
    jrt = JS_NewRuntime();
    if (!jrt) return;
    JS_SetMemoryLimit(jrt, 48 * 1024 * 1024);
    JS_SetMaxStackSize(jrt, 150 * 1024);
    JS_SetInterruptHandler(jrt, js_interrupt, 0);
    JS_SetModuleLoaderFunc(jrt, js_mod_name, js_mod_load, 0);
    jcx = JS_NewContext(jrt);
    if (!jcx) { JS_FreeRuntime(jrt); jrt = 0; return; }
    js_t0 = millis();
    js_next_due = js_t0 + 0x7FFFFFFF;
    js_laid_gen = -1;
    copy(status, "Running the page's scripts ...", sizeof status);
    draw_status(); gfx_blit(frame);
    g = JS_GetGlobalObject(jcx);
    lx = JS_NewObject(jcx);
    JS_SetPropertyFunctionList(jcx, lx, jx_funcs, sizeof jx_funcs / sizeof jx_funcs[0]);
    JS_SetPropertyStr(jcx, g, "__lx", lx);
    js_budget(8000);
    v = JS_Eval(jcx, js_prelude, strlen(js_prelude), "lexos:jsdom.js", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(v)) { js_report(jcx); JS_FreeValue(jcx, g); js_stop(); return; }
    JS_FreeValue(jcx, v);
    j_event_fn = JS_GetPropertyStr(jcx, g, "__lxEvent");
    j_tick_fn = JS_GetPropertyStr(jcx, g, "__lxTick");
    j_start_fn = JS_GetPropertyStr(jcx, g, "__lxStart");
    { JSAtom at = JS_NewAtom(jcx, "__lx"); JS_DeleteProperty(jcx, g, at, 0); JS_FreeAtom(jcx, at); }
    JS_FreeValue(jcx, g);
    js_in_layout = 1;                                    /* (not laid out yet: none to measure) */
    js_budget(8000);
    v = JS_Call(jcx, j_start_fn, JS_UNDEFINED, 0, 0);
    if (JS_IsException(v)) js_report(jcx);
    JS_FreeValue(jcx, v);
    js_jobs();
    js_in_layout = 0;
    status[0] = 0;
}
/* the page's listeners told: type at node (x, y on the page; key...) -> 1 if prevented */
static int js_event(const char *type, int node, int x0, int y0, int key, int code, int mods)
{
    JSValue a[7], r;
    int prevented = 0, i;
    if (!jcx) return 0;
    a[0] = JS_NewString(jcx, type);
    a[1] = jnum(node);
    a[2] = jnum(x0); a[3] = jnum(y0);
    a[4] = jnum(key); a[5] = jnum(code); a[6] = jnum(mods);
    js_budget(3000);
    r = JS_Call(jcx, j_event_fn, JS_UNDEFINED, 7, a);
    for (i = 0; i < 7; i++) JS_FreeValue(jcx, a[i]);
    if (JS_IsException(r)) js_report(jcx); else prevented = JS_ToBool(jcx, r);
    JS_FreeValue(jcx, r);
    js_jobs();
    return prevented;
}
/* the element at the window's mx, my */
static int js_node_at(int mx, int my)
{
    int i, dy = my - VIEW_Y + scroll;
    for (i = nitems - 1; i >= 0; i--) {
        struct item *it = &items[i];
        if (it->kind == IT_NONE || !it->node) continue;
        if (mx >= it->x && mx < it->x + it->w && dy >= it->y && dy < it->y + it->h) {
            int n = it->node;
            while (n && dn[n].type != DN_ELEM) n = dn[n].parent;
            if (n) return n;
        }
    }
    return dom_body;
}
static int js_mods(void)
{
    return (keydown(KEY_LSHIFT) || keydown(KEY_RSHIFT) ? 1 : 0) | (keydown(KEY_CTRL) ? 2 : 0);
}
/* a click on the page (mx, my: the window's) -> 1 if the page said no to it */
static int js_click_at(int mx, int my)
{
    int nd = js_node_at(mx, my), pv;
    pv = js_event("mousedown", nd, mx, my - VIEW_Y, 0, 0, js_mods());
    pv |= js_event("mouseup", nd, mx, my - VIEW_Y, 0, 0, js_mods());
    pv |= js_event("click", nd, mx, my - VIEW_Y, 0, 0, js_mods());
    return pv;
}
/* <a href="javascript:..."> */
static void js_eval_url(const char *code)
{
    char *t = malloc(strlen(code) + 1);
    int i, k = 0;
    if (!t) return;
    for (i = 0; code[i]; i++) {
        if (code[i] == '%' && hexval(code[i + 1]) >= 0 && hexval(code[i + 2]) >= 0) { t[k++] = hexval(code[i + 1]) * 16 + hexval(code[i + 2]); i += 2; }
        else t[k++] = code[i];
    }
    t[k] = 0;
    js_run(t, k, "javascript:", 0);
    js_jobs();
    free(t);
}
/* timers, frames, promises; the page laid out again if it changed -> 1: draw it */
static int js_tick(int force)
{
    unsigned now = millis();
    int changed = 0;
    if (!jcx) return 0;
    if (force || (int)(now - js_next_due) >= 0) {
        JSValue a = JS_NewFloat64(jcx, (double)(unsigned)(now - js_t0)), r;
        js_next_due = now + 0x7FFFFFFF;
        js_budget(3000);
        r = JS_Call(jcx, j_tick_fn, JS_UNDEFINED, 1, &a);
        JS_FreeValue(jcx, a);
        if (JS_IsException(r)) js_report(jcx);
        else if (JS_IsNumber(r)) {
            double d;
            JS_ToFloat64(jcx, &d, r);
            if (d >= 0 && d < 0x7FFFFFFF) { unsigned t = js_t0 + (unsigned)d; if ((int)(t - js_next_due) < 0) js_next_due = t; }
        }
        JS_FreeValue(jcx, r);
        js_jobs();
    }
    if (dom_gen != js_laid_gen && (force || (int)(now - js_last_relayout) > 150)) {
        relayout_keep();
        js_last_relayout = millis();
        changed = 1;
    }
    return changed;
}
#endif
