/* hostmain.c - tools/webtest's main: loads a page, lays it out and
 * saves it whole (shot.ppm) and as the window shows it (screen.ppm). */
#undef main
int host_web_file(const char *url, unsigned char **out, int *n);
static int host_net(const char *u)
{
    unsigned char *b;
    int n, code = host_web_file(u, &b, &n);
    char hdr[512];
    const char *ct = "text/html", *e = u + strlen(u);
    if (code < 0) return -1;
    while (e > u && e[-1] != '.' && e[-1] != '/') e--;
    if (starts_ci(e, "css")) ct = "text/css";
    else if (starts_ci(e, "png")) ct = "image/png";
    else if (starts_ci(e, "jpg") || starts_ci(e, "jpeg")) ct = "image/jpeg";
    else if (starts_ci(e, "gif")) ct = "image/gif";
    else if (starts_ci(e, "webp")) ct = "image/webp";
    else if (starts_ci(e, "svg")) ct = "image/svg+xml";
    else if (starts_ci(e, "js")) ct = "application/javascript";
    else if (starts_ci(e, "json")) ct = "application/json";
    {
        char num[16];
        int k = 0, v = code == 200 ? n : 0;
        do { num[k++] = '0' + v % 10; v /= 10; } while (v);
        hdr[0] = 0;
        append(hdr, code == 200 ? "HTTP/1.1 200 OK\r\nContent-Type: " : "HTTP/1.1 404 Not Found\r\nContent-Type: ", sizeof hdr);
        append(hdr, ct, sizeof hdr);
        append(hdr, "\r\nContent-Length: ", sizeof hdr);
        while (k) { char c[2] = { num[--k], 0 }; append(hdr, c, sizeof hdr); }
        append(hdr, "\r\n\r\n", sizeof hdr);
    }
    if (!ph_feed((unsigned char *)hdr, strlen(hdr)) && code == 200 && n) ph_feed(b, n);
    free(b);
    return 0;
}
#undef open
#undef read
#undef fwrite
#undef close
#undef write
#undef puts
#undef exit
#undef mkdir
/* (stdio's, by hand: quickjs.h's own headers stand in for the system's here) */
typedef unsigned long size_t_;
FILE *fopen(const char *, const char *);
int fprintf(FILE *, const char *, ...);
int fputc(int, FILE *);
int fclose(FILE *);
size_t_ fwrite(const void *, size_t_, size_t_, FILE *);
extern FILE *stderr;
char *getenv(const char *);
void *calloc(size_t_, size_t_);
static void save_ppm(const char *name, const unsigned *p, int w, int h, int stride)
{
    FILE *f = fopen(name, "wb");
    int x, y;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (y = 0; y < h; y++)
        for (x = 0; x < w; x++) { unsigned c = p[y * stride + x]; fputc(c >> 16 & 255, f); fputc(c >> 8 & 255, f); fputc(c & 255, f); }
    fclose(f);
}
int main(int argc, char **argv)
{
    int s, maxh = argc > 2 ? atoi(argv[2]) : 6000, total;
    unsigned *all;
    unsigned t0;
    if (argc < 2) { fprintf(stderr, "webtest page [max height]\n"); return 1; }
    frame = malloc(W * H * 4);
    SRC_ROOM(64 * 1024);
    font(glyphs);
    t0 = millis();
    go(argv[1], 1);
    fprintf(stderr, "laid out: %d items, %d high, %u ms\n", nitems, doc_h, millis() - t0);
    if (getenv("LXKEY") && jcx) {                        /* LXKEY=ch,scancode: a key to the page */
        int ch = atoi(getenv("LXKEY")), sc = 0;
        const char *c = getenv("LXKEY");
        while (*c && *c != ',') c++;
        if (*c) sc = atoi(c + 1);
        fprintf(stderr, "keydown: prevented %d\n", js_event("keydown", dom_body, 0, 0, ch, sc, 0));
        fprintf(stderr, "js_after %d\n", js_after());
    }
    if (getenv("LXEVAL") && jcx) { js_eval_url(getenv("LXEVAL")); js_tick(1); }   /* LXEVAL=code: run on the page */
    if (getenv("LXCLICK")) {                             /* LXCLICK=x,y: a click there (the window's) */
        int cx = atoi(getenv("LXCLICK")), cy = 0;
        const char *c = getenv("LXCLICK");
        while (*c && *c != ',') c++;
        if (*c) cy = atoi(c + 1);
        if (cy >= VIEW_Y && ctrl_at(cx, cy) >= 0) { fprintf(stderr, "(a field)\n"); ctrl_click(ctrl_at(cx, cy)); }
        else if (jcx) js_click_at(cx, cy);
        if (jcx) { js_tick(1); js_after(); }
    }
    {                                                    /* the page's timers, for a while */
        unsigned until = millis() + (getenv("LXJSWAIT") ? atoi(getenv("LXJSWAIT")) : 1000);
        int i;
        while (jcx && (int)(millis() - until) < 0) {
            js_tick(0);
            if (js_after()) break;
            for (i = 0; i < 200000; i++) __asm__ volatile("");
        }
        if (jcx) js_tick(1);
        if (jcx) fprintf(stderr, "scripts: %d run, %d errors; %d items, %d high\n", js_scripts, js_errors, nitems, doc_h);
    }
    if (getenv("LXDUMP")) { FILE *f = fopen("src.html", "wb"); fwrite(src, 1, srclen, f); fclose(f); }
    if (getenv("LXTREE")) {
        int n, d;
        FILE *f = fopen("tree.txt", "w");
        for (n = dom_doc; n; n = dom_next_in(n, dom_doc)) {
            int p2 = n;
            for (d = 0; p2; p2 = dn[p2].parent) d++;
            fprintf(f, "%*s", d * 2, "");
            if (dn[n].type == DN_TEXT) fprintf(f, "\"%.*s\"\n", dn[n].tlen > 60 ? 60 : dn[n].tlen, dstr + dn[n].text);
            else {
                struct cstyle *c = dn[n].cs;
                fprintf(f, "<%s>", atom_name(dn[n].tag));
                if (c) fprintf(f, " d=%d box=%d,%d %dx%d", c->display, dn[n].bx, dn[n].by, dn[n].bw, dn[n].bh);
                fprintf(f, "\n");
            }
        }
        fclose(f);
    }
    if (getenv("LXITEMS")) {                             /* the laid out pieces */
        int i;
        for (i = 0; i < nitems; i++) fprintf(stderr, "item %d: kind %d at %d,%d %dx%d node %d len %d\n", i, items[i].kind, items[i].x, items[i].y, items[i].w, items[i].h, items[i].node, items[i].len);
    }
    redraw();
    save_ppm("screen.ppm", frame, W, H, W);
    total = doc_h < maxh ? doc_h : maxh;
    all = calloc((size_t)W * (total + VIEW_H), 4);
    for (s = 0; s < total; s += VIEW_H) {
        int r;
        scroll = s;
        draw_page();
        for (r = 0; r < VIEW_H && s + r < total; r++) memcpy(all + (size_t)(s + r) * W, frame + (VIEW_Y + r) * W, W * 4);
    }
    save_ppm("shot.ppm", all, W - SBW, total, W);
    return 0;
}
