/* hostlib.c - LexOS's system calls for tools/webtest's LexOS Web on
 * Linux: files under $LXROOT (LexOS's /DEMOS -> $LXROOT/DEMOS), no
 * screen, no keys, no network (pages from the web: hostmain.c's map). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include <ctype.h>
static FILE *fds[64];
static char fpath[64][1024];
static void hpath(const char *n, char *out)
{
    const char *root = getenv("LXROOT");
    snprintf(out, 1024, "%s/%s", root ? root : ".", n[0] == '/' ? n + 1 : n);
}
int lxh_open(const char *n, int mode)
{
    char p[1024];
    int i;
    hpath(n, p);
    for (i = 3; i < 64 && fds[i]; i++) ;
    if (i == 64) return -1;
    fds[i] = fopen(p, mode == 0 ? "rb" : mode == 1 ? "wb" : mode == 2 ? "ab" : "r+b");
    if (!fds[i]) {                                        /* (case: LexOS's names are any case) */
        char *s = p + strlen(p);
        while (s > p && s[-1] != '/') s--;
        for (; *s; s++) *s = toupper(*s);
        fds[i] = fopen(p, mode == 0 ? "rb" : mode == 1 ? "wb" : mode == 2 ? "ab" : "r+b");
    }
    if (!fds[i]) return -1;
    strcpy(fpath[i], p);
    return i;
}
int lxh_read(int fd, void *b, int n) { return fd > 0 && fd < 64 && fds[fd] ? (int)fread(b, 1, n, fds[fd]) : -1; }
int lxh_fwrite(int fd, const void *b, int n) { return fd > 0 && fd < 64 && fds[fd] ? (int)fwrite(b, 1, n, fds[fd]) : -1; }
int lxh_close(int fd) { if (fd > 0 && fd < 64 && fds[fd]) { fclose(fds[fd]); fds[fd] = 0; } return 0; }
int lxh_seek(int fd, int pos) { if (!fds[fd]) return -1; if (pos < 0) fseek(fds[fd], 0, SEEK_END); else fseek(fds[fd], pos, SEEK_SET); return (int)ftell(fds[fd]); }
int lxh_fsize(int fd) { struct stat st; if (!fds[fd] || stat(fpath[fd], &st)) return -1; return (int)st.st_size; }
int lxh_mkdir(const char *n) { char p[1024]; hpath(n, p); return mkdir(p, 0755); }
int lxh_readdir(const char *p, int i, void *e) { (void)p; (void)i; (void)e; return -1; }
void lxh_exit(int c) { exit(c); }
int lxh_write(const char *s, int n) { return (int)fwrite(s, 1, n, stderr); }
void lxh_puts(const char *s) { fputs(s, stderr); }
int lxh_gfx_mode_ex(int w, int h, int b) { (void)w; (void)h; (void)b; return 0; }
void lxh_gfx_blit(const void *f) { (void)f; }
void lxh_gfx_blit_rect(const void *f, int x, int y, int w, int h) { (void)f; (void)x; (void)y; (void)w; (void)h; }
void lxh_font(void *b)
{
    const char *fp = getenv("LXFONT");
    FILE *f = fopen(fp ? fp : "font.bin", "rb");
    memset(b, 0, 4096);
    if (f) { if (fread(b, 1, 4096, f) != 4096) fprintf(stderr, "short font\n"); fclose(f); }
}
void lxh_keymode(int r) { (void)r; }
int lxh_pollkey(void) { return 0; }
int lxh_mouse(int *m) { m[0] = m[1] = m[2] = m[3] = 0; return 0; }
int lxh_inbox(char *b, int n) { (void)b; (void)n; return 0; }
int lxh_keydown(int s) { (void)s; return 0; }
int lxh_clip_text_get(char *b, int n) { (void)b; (void)n; return 0; }
int lxh_clip_text_set(const char *t, int n) { (void)t; (void)n; return 0; }
int lxh_tcp_open(const char *h, int p) { (void)h; (void)p; return -1; }
int lxh_tcp_send(const void *b, int n) { (void)b; (void)n; return -1; }
int lxh_tcp_recv(void *b, int n, int ms) { (void)b; (void)n; (void)ms; return -1; }
void lxh_tcp_close(void) { }
unsigned lxh_millis(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (unsigned)(t.tv_sec * 1000 + t.tv_nsec / 1000000); }
void lxh_sleep_ms(int ms) { (void)ms; }
void lxh_notify(const char *t) { fprintf(stderr, "notify: %s\n", t); }
/* the web, from files: $LXWEB/map.txt lines "https://prefix /host/dir" */
int host_web_file(const char *url, unsigned char **out, int *n)
{
    const char *web = getenv("LXWEB");
    char mp[1024], line[2048];
    FILE *f;
    *out = 0; *n = 0;
    if (!web) return -1;
    snprintf(mp, sizeof mp, "%s/map.txt", web);
    if (!(f = fopen(mp, "r"))) return -1;
    while (fgets(line, sizeof line, f)) {
        char pre[1024], dir[1024], p[2048];
        int l;
        if (sscanf(line, "%1023s %1023s", pre, dir) != 2) continue;
        l = strlen(pre);
        if (!strncmp(url, pre, l)) {
            const char *rest = url + l;
            FILE *g;
            char q[1024];
            int k = 0;
            while (rest[k] && rest[k] != '?' && rest[k] != '#' && k < 1023) { q[k] = rest[k]; k++; }
            q[k] = 0;
            snprintf(p, sizeof p, "%s%s%s", dir, q, (k == 0 || q[k - 1] == '/') ? "index.html" : "");
            fclose(f);
            if (!(g = fopen(p, "rb"))) { fprintf(stderr, "web: no %s (%s)\n", p, url); return 404; }
            fseek(g, 0, SEEK_END); *n = (int)ftell(g); fseek(g, 0, SEEK_SET);
            *out = malloc(*n + 1);
            if (fread(*out, 1, *n, g) != (size_t)*n) *n = 0;
            fclose(g);
            return 200;
        }
    }
    fclose(f);
    fprintf(stderr, "web: unmapped %s\n", url);
    return -1;
}
void lxh_log(int lvl, const char *s, int n) { fprintf(stderr, "[js %c] %.*s\n", lvl, n, s); }
void (*lx_out)(const char *, int);
void lxh_trace(const char *f, int v) { if (getenv("LXTRACE")) fprintf(stderr, f, v); }
