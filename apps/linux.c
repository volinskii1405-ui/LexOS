/* linux.c - LINUX.APP: Linux programs on LexOS.
 *
 * `run busybox ls -l` on a static 32-bit x86 ELF file starts this
 * instead (src/linux.asm), with the same command line. It loads the
 * program where Linux programs expect to be (from 0x08000000: the
 * kernel's "window"), builds the stack Linux gives a program (argv,
 * the environment, the aux vector), and lets it run. Every system call
 * the program makes (int 0x80) comes back here (the kernel "reflects"
 * it: its registers in F, and on in lx_entry), is done with LexOS's own
 * calls, and the program goes on (lx_op RESUME).
 *
 * What there is: files and folders (open, read, write, seek, stat,
 * getdents, mkdir, unlink, rmdir...), a terminal (the text screen as a
 * VT100/"linux" one: colors, cursor movement, erasing, scrolling
 * regions; the keyboard cooked into lines or raw, its keys as escape
 * sequences), time, memory (brk, mmap), thread areas, and processes
 * the way a single one can have them: fork runs the child first, to
 * its end, with the parent's memory put aside and put back (so a shell
 * runs commands, pipes too); execve; wait4; pipes (kept in memory).
 * The paths a Linux program uses are LexOS's ("/DEMOS/README.MD", any
 * case), its file names UTF-8 (LexOS's CP866 on the disk); /dev/null,
 * /dev/tty, /dev/zero, /dev/urandom, /etc/passwd and /proc/self/exe are
 * made up; /bin/<name> is BusyBox's <name> when BusyBox is around.
 * Not there: threads, signals sent (a signal ends the program), sockets,
 * shared memory, dynamic linking (static programs only).
 */
#include "lexos.h"

/* ============================================================
 * the kernel's side (src/linux.asm)
 * ============================================================ */
enum { LXO_REGISTER = 1, LXO_RESUME, LXO_MAP, LXO_TLS, LXO_STAT, LXO_UNLINK, LXO_RMDIR, LXO_TIME,
       LXO_CURSOR, LXO_PUT, LXO_ELF, LXO_TRUNC, LXO_SCREEN, LXO_CWD, LXO_ELFPATH };
static inline int lx_op(int op, int a, int b) { return lx_syscall3(48, op, a, b); }
#define WIN_BASE 0x08000000u
#define WIN_TOP  0x0A000000u

struct frame { unsigned eax, ebx, ecx, edx, esi, edi, ebp, esp, eip, eflags; };
static struct frame F;                                   /* the program's registers, at its call */
static unsigned char hstack[96 * 1024] __attribute__((aligned(16)));
void lx_handle(void);
__asm__(".text\n.globl lx_entry\nlx_entry:\n    call lx_handle\n1:  jmp 1b\n");
extern char lx_entry[];
static void resume(void) { lx_op(LXO_RESUME, 0, 0); for (;;); }

/* ============================================================
 * small things
 * ============================================================ */
static int starts_with(const char *s, const char *p) { while (*p) if (*s++ != *p++) return 0; return 1; }
static char *stpcopy(char *d, const char *s) { while ((*d = *s)) d++, s++; return d; }
static void scopy(char *d, const char *s, int n) { int i = 0; for (; i < n - 1 && s[i]; i++) d[i] = s[i]; d[i] = 0; }
static int lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
static char *utoa(unsigned v, char *out)
{
    char t[12];
    int n = 0;
    do t[n++] = '0' + v % 10; while ((v /= 10));
    while (n) *out++ = t[--n];
    *out = 0;
    return out;
}

/* errno */
enum { EPERM = 1, ENOENT, ESRCH, EINTR, EIO, ENXIO, E2BIG, ENOEXEC, EBADF, ECHILD, EAGAIN, ENOMEM, EACCES, EFAULT,
       EBUSY = 16, EEXIST, EXDEV, ENODEV, ENOTDIR, EISDIR, EINVAL, ENFILE, EMFILE, ENOTTY, EFBIG = 27, ENOSPC,
       ESPIPE, EROFS, EMLINK, EPIPE, ERANGE = 34, ENAMETOOLONG = 36, ENOSYS = 38, ENOTEMPTY, ELOOP,
       EAFNOSUPPORT = 97 };

/* ============================================================
 * text: Linux's UTF-8 <-> LexOS's code page 866 (its font, its names)
 * ============================================================ */
static unsigned cp_uni(unsigned char c)                 /* a CP866 byte -> its letter */
{
    static const unsigned short hi[128] = {
        0x410,0x411,0x412,0x413,0x414,0x415,0x416,0x417,0x418,0x419,0x41A,0x41B,0x41C,0x41D,0x41E,0x41F,
        0x420,0x421,0x422,0x423,0x424,0x425,0x426,0x427,0x428,0x429,0x42A,0x42B,0x42C,0x42D,0x42E,0x42F,
        0x430,0x431,0x432,0x433,0x434,0x435,0x436,0x437,0x438,0x439,0x43A,0x43B,0x43C,0x43D,0x43E,0x43F,
        0x2591,0x2592,0x2593,0x2502,0x2524,0xBF,0xA1,0xE7,0xC7,0x2563,0x2551,0x2557,0x255D,0x255C,0x255B,0x2510,
        0x2514,0x2534,0x252C,0x251C,0x2500,0x253C,0x255E,0x255F,0x255A,0x2554,0x2569,0x2566,0x2560,0x2550,0x256C,0x2567,
        0x2568,0x2564,0x2565,0x2559,0x2558,0x2552,0x2553,0x256B,0x256A,0x2518,0x250C,0x2588,0x2584,0x258C,0x2590,0x2580,
        0x440,0x441,0x442,0x443,0x444,0x445,0x446,0x447,0x448,0x449,0x44A,0x44B,0x44C,0x44D,0x44E,0x44F,
        0x401,0x451,0xE1,0xE9,0xED,0xF3,0xFA,0xF1,0x2219,0x2219,0x221A,0x2116,0xD1,0xFC,0x25A0,0xA0 };
    return c < 128 ? c : hi[c - 128];
}
static int uni_cp(unsigned u)                           /* a letter -> CP866 (-1: none) */
{
    int i;
    if (u < 128) return u;
    if (u >= 0x410 && u <= 0x43F) return 0x80 + u - 0x410;
    if (u >= 0x440 && u <= 0x44F) return 0xE0 + u - 0x440;
    for (i = 128; i < 256; i++) if (cp_uni(i) == u) return i;
    switch (u) {
    case 0x2013: case 0x2014: case 0x2212: return '-';
    case 0x2018: case 0x2019: return '\'';
    case 0x201C: case 0x201D: case 0xAB: case 0xBB: return '"';
    case 0x2022: case 0xB7: return 0xF9;
    case 0xB0: return 0xF8;
    case 0x2192: return 0x1A;
    case 0x2190: return 0x1B;
    case 0x2191: return 0x18;
    case 0x2193: return 0x19;
    case 0x2026: return '.';
    }
    if (u >= 0xC0 && u <= 0xFF) return "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYTsaaaaaaaceeeeiiiidnooooo/ouuuuyty"[u - 0xC0];
    return -1;
}
/* UTF-8 s -> CP866 d (n bytes room) */
static void to_cp(char *d, const char *s, int n)
{
    int k = 0;
    while (*s && k < n - 1) {
        unsigned char c = *s++;
        unsigned u = c;
        int more = 0, b;
        if (c >= 0xF0) { u = c & 7; more = 3; }
        else if (c >= 0xE0) { u = c & 15; more = 2; }
        else if (c >= 0xC0) { u = c & 31; more = 1; }
        while (more-- && (*s & 0xC0) == 0x80) u = u << 6 | (*s++ & 63);
        b = uni_cp(u);
        d[k++] = b < 0 ? '_' : b;
    }
    d[k] = 0;
}
/* CP866 s -> UTF-8 d */
static int to_utf(char *d, const char *s, int n)
{
    int k = 0;
    while (*s && k < n - 4) {
        unsigned u = cp_uni((unsigned char)*s++);
        if (u < 0x80) d[k++] = u;
        else if (u < 0x800) { d[k++] = 0xC0 | u >> 6; d[k++] = 0x80 | (u & 63); }
        else { d[k++] = 0xE0 | u >> 12; d[k++] = 0x80 | (u >> 6 & 63); d[k++] = 0x80 | (u & 63); }
    }
    d[k] = 0;
    return k;
}

/* ============================================================
 * time: the clock (UTC), seconds since 1970
 * ============================================================ */
static unsigned boot_epoch, boot_ms;
static int tz_minutes;
static unsigned days_from(int y, int m, int d)          /* days since 1970-01-01 */
{
    y -= m <= 2;
    {
        int era = y / 400, yoe = y - era * 400;
        int doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
        int doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }
}
static void time_init(void)
{
    unsigned char t[8];
    lx_op(LXO_TIME, (int)t, 0);
    tz_minutes = (short)(t[6] | t[7] << 8) * 60;          /* (the kernel keeps it in hours) */
    boot_epoch = days_from(2000 + t[0], t[1] ? t[1] : 1, t[2] ? t[2] : 1) * 86400u + t[3] * 3600 + t[4] * 60 + t[5];
    boot_ms = millis();
}
static unsigned now_sec(void) { return boot_epoch + (millis() - boot_ms) / 1000; }
static unsigned now_nsec(void) { return (millis() - boot_ms) % 1000 * 1000000u; }
static unsigned stamp_epoch(const unsigned char *m)     /* yy mm dd hh mi -> seconds */
{
    if (!m[1]) return boot_epoch;
    return days_from(2000 + m[0], m[1], m[2] ? m[2] : 1) * 86400u + m[3] * 3600 + m[4] * 60;
}

/* ============================================================
 * the terminal: the 80x25 text screen as a VT100 ("linux") one. What's
 * on it is kept here (scr) and drawn a row piece at a time (lx_op PUT),
 * so a cursor can go anywhere, regions scroll, the last cell can be
 * written without the screen moving. A line feed at the bottom of the
 * whole screen is the console's own (so the desktop's scrollback keeps
 * what goes off the top).
 * ============================================================ */
#define COLS 80
#define ROWS 25
static unsigned short scr[ROWS * COLS];
static int crow, ccol, wrap_pending, top_m, bot_m = ROWS - 1, saved_r, saved_c;
static int def_attr = 0x07, fg = 7, bg = 0, bold, rev, attr = 0x07;
static int dirty_lo = ROWS, dirty_hi = -1;
static int redirected;                                  /* (`> FILE`, `| ...`: the console's text) */
static int cursor_moved;
static void mark(int r) { if (r < dirty_lo) dirty_lo = r; if (r > dirty_hi) dirty_hi = r; }
static void term_init(void)
{
    int rc = lx_op(LXO_CURSOR, 0, 0);
    redirected = rc >> 16 & 1;
    rc &= 0xFFFF;
    lx_op(LXO_SCREEN, (int)scr, 0);
    crow = rc >> 8; ccol = rc & 255;
    if (crow >= ROWS) crow = ROWS - 1;
    if (ccol >= COLS) ccol = COLS - 1;
    def_attr = scr[crow * COLS + ccol] >> 8;
    if (!def_attr || (def_attr & 15) == (def_attr >> 4)) def_attr = 0x07;
    fg = def_attr & 7; bg = def_attr >> 4 & 7; bold = def_attr & 8;
    attr = def_attr;
}
static void set_attr(void)
{
    int f = fg | (bold ? 8 : 0), b = bg;
    attr = rev ? (f & 7) << 4 | b | (b == (f & 7) ? 8 : 0) : b << 4 | f;
}
static void flush_screen(void)
{
    int r;
    if (redirected) return;
    for (r = dirty_lo; r <= dirty_hi; r++) lx_op(LXO_PUT, (int)&scr[r * COLS], r << 16 | 0 << 8 | COLS);
    dirty_lo = ROWS; dirty_hi = -1;
    if (cursor_moved) { setcursor(crow, ccol); cursor_moved = 0; }
}
static void clear_cells(int from, int n)
{
    int i;
    for (i = 0; i < n && from + i < ROWS * COLS; i++) scr[from + i] = ' ' | attr << 8 | 0;
    if (n > 0) { mark(from / COLS); mark((from + n - 1) / COLS < ROWS ? (from + n - 1) / COLS : ROWS - 1); }
}
static void scroll_up(int top, int bot, int n)          /* rows top..bot: n up */
{
    int r;
    if (n > bot - top + 1) n = bot - top + 1;
    if (top == 0 && bot == ROWS - 1 && n == 1) {         /* the whole screen: the console's own */
        flush_screen();
        setcolor(attr);
        setcursor(ROWS - 1, COLS - 1);
        write("\n", 1);
        memmove(scr, scr + COLS, (ROWS - 1) * COLS * 2);
        for (r = 0; r < COLS; r++) scr[(ROWS - 1) * COLS + r] = ' ' | attr << 8;
        cursor_moved = 1;
        return;
    }
    memmove(scr + top * COLS, scr + (top + n) * COLS, (bot - top + 1 - n) * COLS * 2);
    clear_cells((bot - n + 1) * COLS, n * COLS);
    for (r = top; r <= bot; r++) mark(r);
}
static void scroll_down(int top, int bot, int n)
{
    int r;
    if (n > bot - top + 1) n = bot - top + 1;
    memmove(scr + (top + n) * COLS, scr + top * COLS, (bot - top + 1 - n) * COLS * 2);
    clear_cells(top * COLS, n * COLS);
    for (r = top; r <= bot; r++) mark(r);
}
static void line_feed(void)
{
    if (crow == bot_m) scroll_up(top_m, bot_m, 1);
    else if (crow < ROWS - 1) crow++;
    cursor_moved = 1;
}
static void put_glyph(int ch)
{
    if (wrap_pending) { ccol = 0; line_feed(); wrap_pending = 0; }
    scr[crow * COLS + ccol] = (ch & 255) | attr << 8;
    mark(crow);
    if (ccol == COLS - 1) wrap_pending = 1; else ccol++;
    cursor_moved = 1;
}
/* SGR */
static void sgr(int *p, int n)
{
    static const int map[8] = { 0, 4, 2, 6, 1, 5, 3, 7 };  /* ANSI -> VGA */
    int i;
    if (!n) { p[0] = 0; n = 1; }
    for (i = 0; i < n; i++) {
        int v = p[i];
        if (v == 0) { fg = def_attr & 7; bg = def_attr >> 4 & 7; bold = def_attr & 8; rev = 0; }
        else if (v == 1) bold = 1;
        else if (v == 2 || v == 22) bold = 0;
        else if (v == 7) rev = 1;
        else if (v == 27) rev = 0;
        else if (v >= 30 && v <= 37) fg = map[v - 30];
        else if (v == 39) fg = def_attr & 7;
        else if (v >= 40 && v <= 47) bg = map[v - 40];
        else if (v == 49) bg = def_attr >> 4 & 7;
        else if (v >= 90 && v <= 97) { fg = map[v - 90]; bold = 1; }
        else if (v >= 100 && v <= 107) bg = map[v - 100];
        else if ((v == 38 || v == 48) && i + 1 < n) {    /* 256 colors / RGB: near enough */
            int c = -1;
            if (p[i + 1] == 5 && i + 2 < n) { c = p[i + 2]; i += 2; }
            else if (p[i + 1] == 2 && i + 4 < n) {
                c = (p[i + 2] > 127 ? 1 : 0) | (p[i + 3] > 127 ? 2 : 0) | (p[i + 4] > 127 ? 4 : 0);
                i += 4;
            }
            if (c >= 0) {
                int col = c < 16 ? map[c & 7] : 7;
                if (v == 38) { fg = col; if (c >= 8 && c < 16) bold = 1; } else bg = col;
            }
        }
    }
    set_attr();
}
static char in_q[256];                                  /* keys (and answers) waiting to be read */
static int in_n;
static void in_push(const char *s, int n) { while (n-- > 0 && in_n < (int)sizeof in_q) in_q[in_n++] = *s++; }
static int esc_state, esc_np, esc_p[16], esc_priv, utf_need;
static unsigned utf_u;
static void csi(int final)
{
    int *p = esc_p, n = esc_np, a = n ? p[0] : 0, a1 = a ? a : 1, i;
    wrap_pending = 0;
    if (esc_priv == '?') {                                /* modes: shown cursor, the other screen... */
        return;
    }
    switch (final) {
    case 'A': crow -= a1; if (crow < 0) crow = 0; break;
    case 'B': case 'e': crow += a1; if (crow > ROWS - 1) crow = ROWS - 1; break;
    case 'C': case 'a': ccol += a1; if (ccol > COLS - 1) ccol = COLS - 1; break;
    case 'D': ccol -= a1; if (ccol < 0) ccol = 0; break;
    case 'E': crow += a1; ccol = 0; if (crow > ROWS - 1) crow = ROWS - 1; break;
    case 'F': crow -= a1; ccol = 0; if (crow < 0) crow = 0; break;
    case 'G': case '`': ccol = a1 - 1; if (ccol > COLS - 1) ccol = COLS - 1; break;
    case 'd': crow = a1 - 1; if (crow > ROWS - 1) crow = ROWS - 1; break;
    case 'H': case 'f':
        crow = (n > 0 && p[0] ? p[0] : 1) - 1; ccol = (n > 1 && p[1] ? p[1] : 1) - 1;
        if (crow > ROWS - 1) crow = ROWS - 1;
        if (ccol > COLS - 1) ccol = COLS - 1;
        break;
    case 'J':
        if (a == 0) clear_cells(crow * COLS + ccol, ROWS * COLS - (crow * COLS + ccol));
        else if (a == 1) clear_cells(0, crow * COLS + ccol + 1);
        else clear_cells(0, ROWS * COLS);
        break;
    case 'K':
        if (a == 0) clear_cells(crow * COLS + ccol, COLS - ccol);
        else if (a == 1) clear_cells(crow * COLS, ccol + 1);
        else clear_cells(crow * COLS, COLS);
        break;
    case 'X': clear_cells(crow * COLS + ccol, a1 > COLS - ccol ? COLS - ccol : a1); break;
    case 'P':                                             /* delete characters */
        if (a1 > COLS - ccol) a1 = COLS - ccol;
        memmove(scr + crow * COLS + ccol, scr + crow * COLS + ccol + a1, (COLS - ccol - a1) * 2);
        clear_cells(crow * COLS + COLS - a1, a1);
        mark(crow);
        break;
    case '@':                                             /* insert blanks */
        if (a1 > COLS - ccol) a1 = COLS - ccol;
        memmove(scr + crow * COLS + ccol + a1, scr + crow * COLS + ccol, (COLS - ccol - a1) * 2);
        clear_cells(crow * COLS + ccol, a1);
        mark(crow);
        break;
    case 'L': if (crow >= top_m && crow <= bot_m) scroll_down(crow, bot_m, a1); break;
    case 'M': if (crow >= top_m && crow <= bot_m) scroll_up(crow, bot_m, a1); break;
    case 'S': scroll_up(top_m, bot_m, a1); break;
    case 'T': scroll_down(top_m, bot_m, a1); break;
    case 'm': sgr(p, n); break;
    case 'r':
        top_m = (n > 0 && p[0] ? p[0] : 1) - 1; bot_m = (n > 1 && p[1] ? p[1] : ROWS) - 1;
        if (top_m < 0 || top_m >= ROWS) top_m = 0;
        if (bot_m <= top_m || bot_m >= ROWS) bot_m = ROWS - 1;
        crow = ccol = 0;
        break;
    case 's': saved_r = crow; saved_c = ccol; break;
    case 'u': crow = saved_r; ccol = saved_c; break;
    case 'n':
        if (a == 6) {                                     /* where's the cursor? */
            char t[24], *q = t;
            *q++ = 27; *q++ = '[';
            q = utoa(crow + 1, q); *q++ = ';';
            q = utoa(ccol + 1, q); *q++ = 'R';
            in_push(t, q - t);
        } else if (a == 5) in_push("\033[0n", 4);
        break;
    case 'c': in_push("\033[?6c", 5); break;
    }
    (void)i;
    cursor_moved = 1;
}
static void term_byte(unsigned char c)
{
    if (esc_state == 1) {                                 /* after ESC */
        esc_state = 0;
        switch (c) {
        case '[': esc_state = 2; esc_np = 0; esc_p[0] = 0; esc_priv = 0; return;
        case ']': esc_state = 3; return;                  /* a title: to BEL or ST */
        case '(': case ')': case '#': case '%': esc_state = 4; return;
        case '7': saved_r = crow; saved_c = ccol; return;
        case '8': crow = saved_r; ccol = saved_c; cursor_moved = 1; return;
        case 'M': if (crow == top_m) scroll_down(top_m, bot_m, 1); else if (crow) crow--; cursor_moved = 1; return;
        case 'D': line_feed(); return;
        case 'E': ccol = 0; line_feed(); return;
        case 'c': fg = def_attr & 7; bg = def_attr >> 4 & 7; bold = rev = 0; set_attr();
                  top_m = 0; bot_m = ROWS - 1; clear_cells(0, ROWS * COLS); crow = ccol = 0; cursor_moved = 1; return;
        }
        return;
    }
    if (esc_state == 2) {                                 /* CSI */
        if (c >= '0' && c <= '9') { esc_p[esc_np ? esc_np - 1 : 0] = esc_p[esc_np ? esc_np - 1 : 0] * 10 + c - '0'; if (!esc_np) esc_np = 1; return; }
        if (c == ';') { if (!esc_np) esc_np = 1; if (esc_np < 16) esc_p[esc_np++] = 0; return; }
        if (c == '?' || c == '>' || c == '=' || c == '!') { esc_priv = c; return; }
        if (c >= 0x40 && c <= 0x7E) { esc_state = 0; csi(c); return; }
        if (c < 0x20 || c > 0x7E) esc_state = 0;
        return;
    }
    if (esc_state == 3) { if (c == 7 || c == '\\') esc_state = 0; else if (c == 27) esc_state = 3; return; }
    if (esc_state == 4) { esc_state = 0; return; }
    switch (c) {
    case 27: esc_state = 1; return;
    case '\r': ccol = 0; wrap_pending = 0; cursor_moved = 1; return;
    case '\n': case 11: case 12:
        wrap_pending = 0;
        line_feed();
        if (1) ccol = 0;                                  /* (ONLCR: as the console does) */
        return;
    case '\b': if (ccol) ccol--; wrap_pending = 0; cursor_moved = 1; return;
    case '\t': {
        int to = (ccol / 8 + 1) * 8;
        if (to > COLS - 1) to = COLS - 1;
        ccol = to; cursor_moved = 1;
        return;
    }
    case 7: beep(880, 60); return;
    case 0: case 14: case 15: return;
    }
    if (c < 32) return;
    put_glyph(c);
}
/* bytes the program wrote to the terminal: UTF-8, escape sequences */
static void plain_write(const unsigned char *s, int n)
{
    static char out[512];
    int k = 0;
    while (n-- > 0) {
        unsigned char c = *s++;
        if (esc_state) { if (esc_state == 1) esc_state = c == '[' ? 2 : 0; else if (c >= 0x40 && c <= 0x7E) esc_state = 0; continue; }
        if (c == 27) { esc_state = 1; continue; }
        if (utf_need) {
            if ((c & 0xC0) == 0x80) { utf_u = utf_u << 6 | (c & 63); if (!--utf_need) { int b = uni_cp(utf_u); out[k++] = b < 0 ? '?' : b; } }
            else utf_need = 0;
        } else if (c >= 0xC0 && c < 0xF8) { utf_need = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : 1; utf_u = c & (c >= 0xF0 ? 7 : c >= 0xE0 ? 15 : 31); }
        else if (c != '\r') out[k++] = c;
        if (k >= (int)sizeof out - 4) { write(out, k); k = 0; }
    }
    if (k) write(out, k);
}
static void term_write(const unsigned char *s, int n)
{
    if (redirected) { plain_write(s, n); return; }
    while (n-- > 0) {
        unsigned char c = *s++;
        if (utf_need) {
            if ((c & 0xC0) == 0x80) {
                utf_u = utf_u << 6 | (c & 63);
                if (--utf_need) continue;
                if (esc_state) continue;
                {
                    int b = uni_cp(utf_u);
                    if (utf_u >= 0x300 && utf_u < 0x370) continue;     /* (accents on top) */
                    put_glyph(b < 0 ? '?' : b);
                }
                continue;
            }
            utf_need = 0;
            put_glyph('?');
        }
        if (c >= 0xC0 && c < 0xF8 && !esc_state) {
            utf_need = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : 1;
            utf_u = c & (c >= 0xF0 ? 7 : c >= 0xE0 ? 15 : 31);
            continue;
        }
        if (c >= 0x80 && !esc_state) { put_glyph('?'); continue; }
        term_byte(c);
    }
    flush_screen();
}

/* ---- the keyboard: termios (cooked lines, or raw keys) ---- */
struct ktermios { unsigned iflag, oflag, cflag, lflag; unsigned char line, cc[19]; };
#define ISIG 1
#define ICANON 2
#define ECHO 8
#define ICRNL 0x100
#define VINTR 0
#define VERASE 2
#define VKILL 3
#define VEOF 4
#define VTIME 5
#define VMIN 6
static struct ktermios tio = { 0x500, 5, 0xBF, 0x8A3B, 0,
    { 3, 28, 127, 21, 4, 0, 1, 0, 17, 19, 26, 0, 18, 15, 23, 22, 0, 0, 0 } };
static int interrupted;                                 /* Ctrl+C: a SIGINT for the program */
static char line[1024];
static int line_n, line_ready, line_eof;
/* a key -> its bytes on the queue (a Linux terminal's: arrows as
 * escape sequences, Backspace as DEL, letters as UTF-8) */
static void key_bytes(int k)
{
    int ch = k & 255, sc = k >> 8 & 255;
    if (ch == 8 && sc == 0x0E) ch = 127;
    if (ch) {
        if (ch == 13) { in_push(tio.iflag & ICRNL ? "\n" : "\r", 1); return; }
        if (ch >= 0x80) { char t[4]; char s1[2] = { ch, 0 }; int m = to_utf(t, s1, 4); in_push(t, m); return; }
        { char c = ch; in_push(&c, 1); }
        return;
    }
    switch (sc) {
    case 0x48: in_push("\033[A", 3); break;
    case 0x50: in_push("\033[B", 3); break;
    case 0x4D: in_push("\033[C", 3); break;
    case 0x4B: in_push("\033[D", 3); break;
    case 0x47: in_push("\033[H", 3); break;
    case 0x4F: in_push("\033[F", 3); break;
    case 0x49: in_push("\033[5~", 4); break;
    case 0x51: in_push("\033[6~", 4); break;
    case 0x52: in_push("\033[2~", 4); break;
    case 0x53: in_push("\033[3~", 4); break;
    case 0x3B: in_push("\033OP", 3); break;
    case 0x3C: in_push("\033OQ", 3); break;
    case 0x3D: in_push("\033OR", 3); break;
    case 0x3E: in_push("\033OS", 3); break;
    case 0x3F: in_push("\033[15~", 5); break;
    case 0x40: in_push("\033[17~", 5); break;
    case 0x41: in_push("\033[18~", 5); break;
    case 0x42: in_push("\033[19~", 5); break;
    case 0x43: in_push("\033[20~", 5); break;
    case 0x44: in_push("\033[21~", 5); break;
    }
}
/* the keys there are, onto the queue (no waiting) */
static void keys_poll(void)
{
    int k;
    while (in_n < (int)sizeof in_q - 8 && (k = pollkey())) {
        if ((k & 255) == 3 && (tio.lflag & ISIG)) { interrupted = 1; in_n = 0; line_n = 0; line_ready = 0; return; }
        key_bytes(k);
    }
}
static void keys_wait(void)                             /* at least one key there */
{
    while (!in_n && !interrupted) {
        int k = getkey_full();
        if ((k & 255) == 3 && (tio.lflag & ISIG)) { interrupted = 1; line_n = 0; line_ready = 0; return; }
        key_bytes(k);
    }
}
static int in_take(char *buf, int n)
{
    int k = n < in_n ? n : in_n;
    memcpy(buf, in_q, k);
    memmove(in_q, in_q + k, in_n - k);
    in_n -= k;
    return k;
}
/* a cooked line: typed and edited here, echoed */
static void echo_str(const char *s, int n) { if (tio.lflag & ECHO) term_write((const unsigned char *)s, n); }
static int term_read(char *buf, int n, int nonblock)
{
    if (!(tio.lflag & ICANON)) {                          /* raw */
        int vmin = tio.cc[VMIN], vtime = tio.cc[VTIME];
        flush_screen();
        keys_poll();
        if (!in_n && !nonblock) {
            if (vmin == 0 && vtime == 0) return 0;
            if (vmin == 0) {                              /* up to VTIME tenths */
                unsigned until = millis() + vtime * 100;
                while (!in_n && !interrupted && (int)(until - millis()) > 0) { sleep_ms(10); keys_poll(); }
            } else keys_wait();
        }
        if (interrupted) return -EINTR;
        if (!in_n) return nonblock ? -EAGAIN : 0;
        {
            int k = in_take(buf, n);
            if (tio.lflag & ECHO) echo_str(buf, k);
            return k;
        }
    }
    while (!line_ready) {                                 /* cooked: a whole line first */
        char c;
        flush_screen();
        if (nonblock) { keys_poll(); if (!in_n) return -EAGAIN; }
        keys_wait();
        if (interrupted) return -EINTR;
        while (in_n && !line_ready) {
            in_take(&c, 1);
            if ((unsigned char)c == tio.cc[VERASE] || c == 8) {
                if (line_n) {
                    while (line_n > 1 && (line[line_n - 1] & 0xC0) == 0x80) line_n--;   /* (a whole letter) */
                    line_n--;
                    echo_str("\b \b", 3);
                }
            } else if (c == tio.cc[VKILL]) {
                while (line_n) { line_n--; if ((line[line_n] & 0xC0) != 0x80) echo_str("\b \b", 3); }
            } else if (c == tio.cc[VEOF]) {
                line_ready = 1;
                if (!line_n) line_eof = 1;
            } else if (c == 27) {                         /* (an arrow's sequence: not in a line) */
                char t[8];
                int m = in_take(t, in_n < 3 ? in_n : (in_n > 0 && in_q[1] >= '0' && in_q[1] <= '9' ? 3 : 2));
                (void)m;
            } else if (c == '\n' || c == '\r') {
                if (line_n < (int)sizeof line) line[line_n++] = '\n';
                echo_str("\n", 1);
                line_ready = 1;
            } else if ((unsigned char)c >= 32 || c == '\t') {
                if (line_n < (int)sizeof line - 2) { line[line_n++] = c; echo_str(&c, 1); }
            }
        }
    }
    if (line_eof) { line_eof = line_ready = 0; line_n = 0; return 0; }
    {
        int k = n < line_n ? n : line_n;
        memcpy(buf, line, k);
        memmove(line, line + k, line_n - k);
        line_n -= k;
        if (!line_n) line_ready = 0;
        return k;
    }
}

/* ============================================================
 * files: open file descriptions (shared by dup'd and forked fds) and
 * each process's table of fds
 * ============================================================ */
enum { OT_TTY = 1, OT_FILE, OT_DIR, OT_NULL, OT_ZERO, OT_RANDOM, OT_PIPE_R, OT_PIPE_W, OT_TEXT };
struct pipe { char *buf; int len, cap, rd, readers, writers; };
struct ofd {
    int type, refs, flags, handle;
    unsigned pos;
    char path[160];                                      /* (LexOS's: CP866) */
    int dirpos;
    struct pipe *pipe;
    char *text; int tlen;                                /* (made-up files) */
};
#define NFD 64
struct fdent { struct ofd *o; int cloexec; };

/* ============================================================
 * processes: up to NPROC of them, one at a time. The one running (cur)
 * has its memory in place; the others' is put aside - the bytes it can
 * change (its data, its heap, its stack; the mmap blocks it shares) -
 * and put back when it runs again (its program's code is read from the
 * file again if another program's is there). A fork's child runs
 * first; a process that has to wait - for a pipe's bytes, for room in
 * one, for a child to end - lets another one run.
 * ============================================================ */
#define NPROC 16
enum { PS_FREE, PS_RUN, PS_READY, PS_BLOCKED, PS_ZOMBIE };
enum { BK_PIPE_R = 1, BK_PIPE_W, BK_WAIT };
struct map { unsigned addr, len; char *raw; unsigned seen; char *save[NPROC]; };
#define NMAPS 256
static struct map maps[NMAPS];
static int nmaps;
struct seg { unsigned off, vaddr, filesz; };
struct proc {
    int state, pid, ppid, umask, status;
    int bk, bk_pid, noblock; void *bk_on;                /* blocked: on what */
    struct fdent fd[NFD];
    char cwd[256], exe[256];                             /* (CP866) */
    unsigned img_lo, rw_lo, brk;
    struct seg ro[4]; int nro;                           /* (its code: read again) */
    unsigned tls_base, tls_lim; int tls_on;
    struct frame regs;                                   /* (while it isn't running) */
    char *rw; unsigned rw_len;                           /* (put aside) */
    char *stk; unsigned stk_lo, stk_len;
    struct sigact { unsigned handler, flags, restorer, mask[2]; } sa[65];
    unsigned blocked, pending;                           /* (signals 1..31) */
    struct frame sigsave[8]; unsigned sigmask_save[8]; int nsig;
};
static struct proc procs[NPROC];
static int cur;
#define P (&procs[cur])
static int next_pid = 101;
static char win_exe[256];                                /* whose code the window has */
static char *stack_mem;                                  /* the Linux programs' stack */
#define STACK_SIZE (1024 * 1024)
static unsigned stack_top;
static void wake(int kind, void *on);

static struct ofd *ofd_new(int type)
{
    struct ofd *o = malloc(sizeof *o);
    if (!o) return 0;
    memset(o, 0, sizeof *o);
    o->type = type; o->refs = 1; o->handle = -1;
    return o;
}
static void ofd_put(struct ofd *o)
{
    if (!o || --o->refs > 0) return;
    if (o->type == OT_FILE && o->handle >= 0) close(o->handle);
    if (o->type == OT_PIPE_R && o->pipe) { o->pipe->readers--; wake(BK_PIPE_W, o->pipe); }
    if (o->type == OT_PIPE_W && o->pipe) { o->pipe->writers--; wake(BK_PIPE_R, o->pipe); }
    if (o->pipe && o->pipe->readers <= 0 && o->pipe->writers <= 0) { free(o->pipe->buf); free(o->pipe); }
    free(o->text);
    free(o);
}
static int fd_new(struct ofd *o, int from)
{
    int i;
    for (i = from; i < NFD; i++) if (!P->fd[i].o) { P->fd[i].o = o; P->fd[i].cloexec = 0; return i; }
    return -EMFILE;
}
static struct ofd *fd_get(int fd) { return fd >= 0 && fd < NFD ? P->fd[fd].o : 0; }

/* ---- paths: a Linux program's -> LexOS's (absolute, CP866) ---- */
static int norm_path(const char *upath, char *out, int cap)
{
    static char tmp[512], acc[512];
    char *parts[64];
    int np = 0, i, k = 0;
    to_cp(tmp, upath, sizeof tmp);
    if (tmp[0] != '/') {
        char *q = stpcopy(acc, P->cwd);
        if (q[-1] != '/') *q++ = '/';
        scopy(q, tmp, sizeof acc - (q - acc));
    } else scopy(acc, tmp, sizeof acc);
    {
        char *s = acc;
        while (*s) {
            char *b;
            while (*s == '/') s++;
            if (!*s) break;
            b = s;
            while (*s && *s != '/') s++;
            if (*s) *s++ = 0;
            if (!strcmp(b, ".")) continue;
            if (!strcmp(b, "..")) { if (np) np--; continue; }
            if (np < 64) parts[np++] = b;
        }
    }
    if (!np) { scopy(out, "/", cap); return 0; }
    for (i = 0; i < np; i++) {
        int l = strlen(parts[i]);
        if (k + l + 2 >= cap) return -ENAMETOOLONG;
        out[k++] = '/';
        memcpy(out + k, parts[i], l);
        k += l;
    }
    out[k] = 0;
    return 0;
}
static int path_at(int dirfd, const char *upath, char *out, int cap)
{
    if (!upath) return -EFAULT;
    if (upath[0] != '/' && dirfd != -100) {               /* (relative to a folder fd) */
        struct ofd *o = fd_get(dirfd);
        static char t[512];
        char *q;
        if (!o) return -EBADF;
        if (o->type != OT_DIR) return -ENOTDIR;
        to_utf(t, o->path, sizeof t - 2);
        q = t + strlen(t);
        *q++ = '/';
        scopy(q, upath, sizeof t - (q - t));
        return norm_path(t, out, cap);
    }
    return norm_path(upath, out, cap);
}

/* ---- what a path is (lx_op STAT) ---- */
struct lxstat { int type, size; unsigned char mtime[8]; int attr, slot, pad[2]; };
static int busybox_known;
static char busybox_path[160];
static char *applets;                                    /* "[\0[[\0ls\0...\0\0" from BusyBox */
static int is_bin_dir(const char *p)                    /* /bin/x, /usr/bin/x, /sbin/x ... */
{
    return starts_with(p, "/bin/") || starts_with(p, "/usr/bin/") || starts_with(p, "/sbin/") ||
           starts_with(p, "/usr/sbin/") || starts_with(p, "/usr/local/bin/");
}
static int same_ci(const char *a, const char *b)
{
    while (*a && lower(*a) == lower(*b)) a++, b++;
    return !*a && !*b;
}
static const char *base_name(const char *p) { const char *b = p; for (; *p; p++) if (*p == '/') b = p + 1; return b; }
static int is_applet(const char *name)
{
    const char *a = applets;
    if (!busybox_known) return 0;
    if (!a) return 1;
    for (; *a; a += strlen(a) + 1) {
        int i = 0;
        while (a[i] && lower(a[i]) == lower(name[i])) i++;
        if (!a[i] && !name[i]) return 1;
    }
    return 0;
}
static int vstat(const char *p, struct lxstat *st)      /* -> 0, or -ENOENT */
{
    memset(st, 0, sizeof *st);
    if (!lx_op(LXO_STAT, (int)p, (int)st)) return 0;
    if (!strcmp(p, "/dev") || !strcmp(p, "/proc") || !strcmp(p, "/etc") || !strcmp(p, "/bin") ||
        !strcmp(p, "/usr") || !strcmp(p, "/usr/bin") || !strcmp(p, "/sbin")) {
        st->type = 2; st->slot = -2; return 0;
    }
    if (is_bin_dir(p) && is_applet(base_name(p))) { st->type = 1; st->slot = -3; st->size = 0; return 0; }
    return -ENOENT;
}
static int file_mode(const char *p, struct lxstat *st)
{
    const char *b = base_name(p), *d = b;
    int exec = 0;
    if (st->type == 2) return 040755;
    while (*d && *d != '.') d++;
    if (!*d || st->slot == -3) exec = 1;                 /* (no extension: a Unix program) */
    else if (!strcmp(d, ".APP") || !strcmp(d, ".app") || !strcmp(d, ".sh") || !strcmp(d, ".SH")) exec = 1;
    return 0100000 | ((exec ? 0755 : 0644) & ~(st->attr & 1 ? 0222 : 0));
}

/* struct stat64 (i386) */
static void fill_stat64(unsigned char *b, int mode, unsigned size, unsigned ino, unsigned mtime, unsigned rdev)
{
    memset(b, 0, 96);
    *(unsigned *)(b + 0) = 0x801;                        /* st_dev */
    *(unsigned *)(b + 12) = ino;
    *(unsigned *)(b + 16) = mode;
    *(unsigned *)(b + 20) = (mode & 0170000) == 040000 ? 2 : 1;
    *(unsigned *)(b + 32) = rdev;
    *(unsigned *)(b + 44) = size;
    *(unsigned *)(b + 52) = 4096;
    *(unsigned *)(b + 56) = (size + 511) / 512;
    *(unsigned *)(b + 64) = mtime;
    *(unsigned *)(b + 72) = mtime;
    *(unsigned *)(b + 80) = mtime;
    *(unsigned *)(b + 88) = ino;
}
static void fill_stat_old(unsigned char *b, int mode, unsigned size, unsigned ino, unsigned mtime, unsigned rdev)
{
    memset(b, 0, 64);
    *(unsigned *)(b + 0) = 0x801;
    *(unsigned *)(b + 4) = ino;
    *(unsigned short *)(b + 8) = mode;
    *(unsigned short *)(b + 10) = (mode & 0170000) == 040000 ? 2 : 1;
    *(unsigned *)(b + 16) = rdev;
    *(unsigned *)(b + 20) = size;
    *(unsigned *)(b + 24) = 4096;
    *(unsigned *)(b + 28) = (size + 511) / 512;
    *(unsigned *)(b + 32) = mtime;
    *(unsigned *)(b + 40) = mtime;
    *(unsigned *)(b + 48) = mtime;
}
static void fill_statx(unsigned char *b, int mode, unsigned size, unsigned ino, unsigned mtime, unsigned rdev)
{
    memset(b, 0, 256);
    *(unsigned *)(b + 0) = 0x7FF;                        /* the basic stats */
    *(unsigned *)(b + 4) = 4096;
    *(unsigned *)(b + 16) = (mode & 0170000) == 040000 ? 2 : 1;
    *(unsigned short *)(b + 28) = mode;
    *(unsigned *)(b + 32) = ino;
    *(unsigned *)(b + 40) = size;
    *(unsigned *)(b + 48) = (size + 511) / 512;
    *(unsigned *)(b + 64) = mtime;
    *(unsigned *)(b + 80) = mtime;
    *(unsigned *)(b + 96) = mtime;
    *(unsigned *)(b + 112) = mtime;
    *(unsigned *)(b + 128) = rdev >> 8;
    *(unsigned *)(b + 132) = rdev & 255;
    *(unsigned *)(b + 136) = 8;
    *(unsigned *)(b + 140) = 1;
}
enum { SF_64, SF_OLD, SF_X };
static void fill_any(int form, unsigned char *b, int mode, unsigned size, unsigned ino, unsigned mtime, unsigned rdev)
{
    if (form == SF_64) fill_stat64(b, mode, size, ino, mtime, rdev);
    else if (form == SF_OLD) fill_stat_old(b, mode, size, ino, mtime, rdev);
    else fill_statx(b, mode, size, ino, mtime, rdev);
}
/* made-up files */
static const char *dev_kind(const char *p)
{
    static const char *devs[] = { "/dev/null", "/dev/zero", "/dev/tty", "/dev/console", "/dev/urandom",
                                  "/dev/random", "/dev/stdin", "/dev/stdout", "/dev/stderr", "/dev/full", 0 };
    int i;
    for (i = 0; devs[i]; i++) if (!strcmp(p, devs[i])) return devs[i];
    if (starts_with(p, "/dev/tty") || starts_with(p, "/dev/pts/") || starts_with(p, "/proc/self/fd/")) return "/dev/tty";
    return 0;
}
static char *made_text(const char *p, int *len)
{
    static char t[2048];
    char *q = t;
    t[0] = 0;
    if (!strcmp(p, "/etc/passwd")) q = stpcopy(t, "root:x:0:0:root:/:/bin/sh\n");
    else if (!strcmp(p, "/etc/group")) q = stpcopy(t, "root:x:0:\n");
    else if (!strcmp(p, "/etc/hostname")) q = stpcopy(t, "lexos\n");
    else if (!strcmp(p, "/etc/hosts")) q = stpcopy(t, "127.0.0.1 localhost lexos\n");
    else if (!strcmp(p, "/etc/shells")) q = stpcopy(t, "/bin/sh\n/bin/ash\n");
    else if (!strcmp(p, "/etc/os-release")) q = stpcopy(t, "NAME=\"LexOS\"\nID=lexos\nPRETTY_NAME=\"LexOS (running a Linux program)\"\n");
    else if (!strcmp(p, "/proc/cpuinfo")) q = stpcopy(t, "processor\t: 0\nvendor_id\t: LexOS\nmodel name\t: x86 (LexOS)\nflags\t\t: fpu tsc cx8 cmov mmx sse sse2\n\n");
    else if (!strcmp(p, "/proc/meminfo")) q = stpcopy(t, "MemTotal:       262144 kB\nMemFree:        131072 kB\nMemAvailable:   131072 kB\n");
    else if (!strcmp(p, "/proc/version")) q = stpcopy(t, "Linux version 5.10.0-lexos (LexOS's LINUX.APP)\n");
    else if (!strcmp(p, "/proc/uptime")) { q = utoa((millis()) / 1000, t); q = stpcopy(q, ".00 0.00\n"); }
    else if (!strcmp(p, "/proc/loadavg")) q = stpcopy(t, "0.00 0.00 0.00 1/1 1\n");
    else if (!strcmp(p, "/proc/mounts") || !strcmp(p, "/etc/mtab")) q = stpcopy(t, "/dev/hda1 / vfat rw 0 0\n");
    else if (!strcmp(p, "/proc/self/stat")) q = stpcopy(t, "1 (prog) R 0 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0\n");
    else return 0;
    *len = q - t;
    {
        char *r = malloc(*len + 1);
        if (r) memcpy(r, t, *len + 1);
        return r;
    }
}

/* ============================================================
 * memory: the window (the program, then its brk heap) and mmap's
 * blocks (from LINUX.APP's own heap, page-aligned)
 * ============================================================ */
static unsigned win_mapped = WIN_BASE;
static int win_need(unsigned top)                       /* the window up to top -> 0, or -ENOMEM */
{
    if (top <= win_mapped) return 0;
    if (top > WIN_TOP) return -ENOMEM;
    {
        unsigned t = lx_op(LXO_MAP, (int)top, 0);
        if (!t) return -ENOMEM;
        win_mapped = t;
    }
    return 0;
}
static unsigned sys_brk(unsigned to)
{
    unsigned pg;
    if (!to || to < P->rw_lo) return P->brk;
    pg = (to + 4095) & ~4095u;
    if (win_need(pg)) return P->brk;
    if (to > P->brk) memset((void *)P->brk, 0, to - P->brk);
    P->brk = to;
    return P->brk;
}
static int map_find(unsigned addr)
{
    int i;
    for (i = 0; i < nmaps; i++) if ((maps[i].seen >> cur & 1) && addr >= maps[i].addr && addr < maps[i].addr + maps[i].len) return i;
    return -1;
}
/* process k no longer sees block i (gone, when nobody does) */
static void map_unsee(int i, int k)
{
    maps[i].seen &= ~(1u << k);
    free(maps[i].save[k]); maps[i].save[k] = 0;
    if (!maps[i].seen) { int j; free(maps[i].raw); for (j = 0; j < NPROC; j++) free(maps[i].save[j]); maps[i] = maps[--nmaps]; }
}
static void maps_unsee_all(int k)
{
    int i;
    for (i = nmaps - 1; i >= 0; i--) if (maps[i].seen >> k & 1) map_unsee(i, k);
}
static int sys_mmap(unsigned addr, unsigned len, int prot, int flags, int fd, unsigned off)
{
    char *raw;
    unsigned a;
    (void)prot;
    if (!len) return -EINVAL;
    len = (len + 4095) & ~4095u;
    if (flags & 0x10) {                                   /* MAP_FIXED: only over what's ours */
        int i = map_find(addr);
        if (i >= 0 && addr + len <= maps[i].addr + maps[i].len) { if (flags & 0x20) memset((void *)addr, 0, len); a = addr; goto data; }
        if (addr >= P->img_lo && addr + len <= win_mapped) { if (flags & 0x20) memset((void *)addr, 0, len); a = addr; goto data; }
        return -ENOMEM;
    }
    if (nmaps >= NMAPS) return -ENOMEM;
    raw = malloc(len + 4095);
    if (!raw) return -ENOMEM;
    a = ((unsigned)raw + 4095) & ~4095u;
    memset((void *)a, 0, len);
    memset(&maps[nmaps], 0, sizeof maps[nmaps]);
    maps[nmaps].addr = a; maps[nmaps].len = len; maps[nmaps].raw = raw;
    maps[nmaps].seen = 1u << cur;
    nmaps++;
data:
    if (!(flags & 0x20)) {                                /* a file's bytes, read in */
        struct ofd *o = fd_get(fd);
        if (!o || o->type != OT_FILE) return (int)a;
        seek(o->handle, off);
        read(o->handle, (void *)a, len);
        seek(o->handle, o->pos);
    }
    return (int)a;
}
static int sys_munmap(unsigned addr, unsigned len)
{
    int i = map_find(addr);
    len = (len + 4095) & ~4095u;
    if (i < 0 || maps[i].addr != addr || len < maps[i].len) return 0;   /* (a part of one: it stays) */
    map_unsee(i, cur);
    return 0;
}

/* ============================================================
 * loading a program (the first one, and execve's)
 * ============================================================ */
struct ehdr { unsigned char ident[16]; unsigned short type, machine; unsigned version, entry, phoff, shoff, flags;
              unsigned short ehsize, phentsize, phnum, shentsize, shnum, shstrndx; };
struct phdr { unsigned type, offset, vaddr, paddr, filesz, memsz, flags, align; };
static const char *load_err;
static char exe_name[256];
static unsigned auxv_phdr, auxv_phnum, auxv_entry;
/* reads the ELF file on handle h into the window -> 0, or -errno */
static int load_elf(int h)
{
    struct ehdr eh;
    static struct phdr ph[32];
    unsigned lo = 0xFFFFFFFF, hi = 0, bias = 0;
    int i;
    load_err = "not a program LexOS can run";
    seek(h, 0);
    if (read(h, &eh, sizeof eh) != sizeof eh || memcmp(eh.ident, "\177ELF", 4)) return -ENOEXEC;
    if (eh.ident[4] != 1 || eh.machine != 3) { load_err = eh.ident[4] == 2 ? "a 64-bit program (LexOS runs 32-bit x86 ones)" : "not for x86"; return -ENOEXEC; }
    if (eh.type != 2 && eh.type != 3) return -ENOEXEC;
    if (eh.phnum > 32 || eh.phentsize != sizeof(struct phdr)) return -ENOEXEC;
    seek(h, eh.phoff);
    if (read(h, ph, eh.phnum * sizeof *ph) != (int)(eh.phnum * sizeof *ph)) return -ENOEXEC;
    for (i = 0; i < eh.phnum; i++) {
        if (ph[i].type == 3) { load_err = "it needs shared libraries (only static programs run here)"; return -ENOEXEC; }
        if (ph[i].type != 1) continue;
        if (ph[i].vaddr < lo) lo = ph[i].vaddr;
        if (ph[i].vaddr + ph[i].memsz > hi) hi = ph[i].vaddr + ph[i].memsz;
    }
    if (hi <= lo) return -ENOEXEC;
    if (eh.type == 3) bias = 0x08048000 - (lo & ~4095u); /* (position-independent: put there) */
    lo = (lo + bias) & ~4095u;
    hi = (hi + bias + 4095) & ~4095u;
    if (lo < WIN_BASE || hi > WIN_TOP - 0x100000) { load_err = "it wants its memory where LexOS can't give it (not 0x08000000...)"; return -ENOMEM; }
    if (win_need(hi + 0x10000)) { load_err = "there isn't enough memory for it"; return -ENOMEM; }
    memset((void *)lo, 0, hi - lo);
    auxv_phdr = 0;
    P->nro = 0;
    P->rw_lo = hi;
    for (i = 0; i < eh.phnum; i++) {
        if (ph[i].type == 6) auxv_phdr = ph[i].vaddr + bias;
        if (ph[i].type != 1) continue;
        if (!(ph[i].flags & 2) && P->nro < 4 && ph[i].memsz == ph[i].filesz) {     /* code: read again later */
            P->ro[P->nro].off = ph[i].offset; P->ro[P->nro].vaddr = ph[i].vaddr + bias; P->ro[P->nro].filesz = ph[i].filesz;
            P->nro++;
        } else if (((ph[i].vaddr + bias) & ~4095u) < P->rw_lo) P->rw_lo = (ph[i].vaddr + bias) & ~4095u;
        if (ph[i].filesz) {
            seek(h, ph[i].offset);
            if (read(h, (void *)(ph[i].vaddr + bias), ph[i].filesz) != (int)ph[i].filesz) { load_err = "the file is cut short"; return -EIO; }
        }
        if (!auxv_phdr && eh.phoff >= ph[i].offset && eh.phoff < ph[i].offset + ph[i].filesz)
            auxv_phdr = ph[i].vaddr + bias + eh.phoff - ph[i].offset;
    }
    auxv_phnum = eh.phnum;
    auxv_entry = eh.entry + bias;
    P->img_lo = lo;
    if (P->rw_lo < lo) P->rw_lo = lo;
    P->brk = hi;
    scopy(win_exe, P->exe, sizeof win_exe);
    return 0;
}
/* the stack a Linux program starts with: argc, argv, envp, auxv, and
 * the strings they point at -> its esp */
static unsigned build_stack(char **argv, char **envp)
{
    unsigned sp = stack_top;
    int argc = 0, envc = 0, i;
    static unsigned aptr[256], eptr[256];
    unsigned rnd, plat, execfn, *w;
    while (argv[argc] && argc < 255) argc++;
    while (envp[envc] && envc < 255) envc++;
#define PUSH_STR(s) do { int l_ = strlen(s) + 1; sp -= l_; memcpy((void *)sp, s, l_); } while (0)
    PUSH_STR(exe_name); execfn = sp;
    PUSH_STR("i686"); plat = sp;
    for (i = envc - 1; i >= 0; i--) { PUSH_STR(envp[i]); eptr[i] = sp; }
    for (i = argc - 1; i >= 0; i--) { PUSH_STR(argv[i]); aptr[i] = sp; }
    sp -= 16; rnd = sp;
    for (i = 0; i < 16; i++) ((unsigned char *)sp)[i] = (millis() * 2654435761u >> (i & 7)) ^ (i * 77);
    sp &= ~15u;
    {
        int words = 1 + argc + 1 + envc + 1 + 2 * 16;
        sp -= words * 4;
        sp &= ~15u;
    }
    w = (unsigned *)sp;
    *w++ = argc;
    for (i = 0; i < argc; i++) *w++ = aptr[i];
    *w++ = 0;
    for (i = 0; i < envc; i++) *w++ = eptr[i];
    *w++ = 0;
#define AUX(t, v) do { *w++ = (t); *w++ = (v); } while (0)
    AUX(3, auxv_phdr); AUX(4, 32); AUX(5, auxv_phnum); AUX(6, 4096); AUX(7, 0); AUX(8, 0);
    AUX(9, auxv_entry); AUX(11, 0); AUX(12, 0); AUX(13, 0); AUX(14, 0); AUX(16, 0x178BFBFF);
    AUX(17, 100); AUX(23, 0); AUX(25, rnd); AUX(15, plat); AUX(31, execfn); AUX(0, 0);
    return sp;
}

/* ============================================================
 * BusyBox: where it is, and its applets' names (for /bin/<name>)
 * ============================================================ */
static void find_applets(int h)
{
    static char buf[65536];
    int got, pos = 0;
    seek(h, 0);
    while ((got = read(h, buf, sizeof buf)) > 0) {
        int i;
        for (i = 0; i + 5 < got; i++)
            if (buf[i] == '[' && buf[i + 1] == 0 && buf[i + 2] == '[' && buf[i + 3] == '[' && buf[i + 4] == 0) {
                static char names[16384];
                int k = 0, j = i;
                if (got - i < 4096) { seek(h, pos + i); got = read(h, buf, sizeof buf); j = 0; }
                while (j < got && k < (int)sizeof names - 2) {
                    char c = buf[j++];
                    names[k++] = c;
                    if (!c && !buf[j]) break;
                    if (c && (c < 32 || c > 126)) { k = 0; break; }
                }
                if (k > 100) { names[k] = 0; names[k + 1] = 0; applets = names; }
                return;
            }
        pos += got;
        if (pos > 4 * 1024 * 1024) return;
    }
}
static void note_busybox(const char *path, int h)
{
    if (busybox_known) return;
    busybox_known = 1;
    scopy(busybox_path, path, sizeof busybox_path);
    find_applets(h);
}

/* ============================================================
 * the system calls
 * ============================================================ */
static int trace;
static void trace_call(unsigned nr, int r)
{
    char t[96], *q = t;
    q = stpcopy(q, "\033[36m[");
    q = utoa(nr, q); q = stpcopy(q, "(");
    q = utoa(F.ebx, q); q = stpcopy(q, ",");
    q = utoa(F.ecx, q); q = stpcopy(q, ",");
    q = utoa(F.edx, q); q = stpcopy(q, ")=");
    if (r < 0) { *q++ = '-'; q = utoa(-r, q); } else q = utoa(r, q);
    q = stpcopy(q, "]\033[0m");
    term_write((unsigned char *)t, q - t);
}

/* exit: the process ends (a child: its parent goes on) */
static void proc_exit(int status);
static void deliver(unsigned nr, int r);
static int do_open(const char *p, int flags, int mode);
static int do_execve(const char *upath, char **uargv, char **uenvp);

static int rw_file(struct ofd *o, void *buf, int n, int writing)
{
    int r;
    if (o->handle < 0) return -EBADF;
    if (writing && (o->flags & 0x400)) { o->pos = fsize(o->handle); }
    seek(o->handle, o->pos);
    r = writing ? fwrite(o->handle, buf, n) : read(o->handle, buf, n);
    if (r < 0) return -EIO;
    o->pos += r;
    return r;
}
static int block(int kind, void *on);
static int pipe_read(struct pipe *pp, char *buf, int n)
{
    int k = pp->len - pp->rd;
    if (!k && pp->writers > 0) block(BK_PIPE_R, pp);     /* (empty: wait for its writer - or, with */
    if (!k) return 0;                                     /*  nobody else to run, the end) */
    wake(BK_PIPE_W, pp);
    if (k > n) k = n;
    memcpy(buf, pp->buf + pp->rd, k);
    pp->rd += k;
    if (pp->rd == pp->len) pp->rd = pp->len = 0;
    return k;
}
static int pipe_write(struct pipe *pp, const char *buf, int n)
{
    if (pp->readers <= 0) return -EPIPE;
    if (pp->len - pp->rd >= 1024 * 1024) block(BK_PIPE_W, pp);   /* (full enough: let its reader read) */
    if (pp->rd && pp->len + n > pp->cap) {                /* (what's been read: out) */
        memmove(pp->buf, pp->buf + pp->rd, pp->len - pp->rd);
        pp->len -= pp->rd; pp->rd = 0;
    }
    if (pp->len + n > pp->cap) {
        int c = pp->cap ? pp->cap : 4096;
        char *b;
        while (c < pp->len + n) c *= 2;
        if (c > 8 * 1024 * 1024) return -EPIPE;           /* (nobody's reading it as it's written) */
        b = malloc(c);
        if (!b) return -ENOMEM;
        if (pp->buf) { memcpy(b, pp->buf, pp->len); free(pp->buf); }
        pp->buf = b; pp->cap = c;
    }
    memcpy(pp->buf + pp->len, buf, n);
    pp->len += n;
    wake(BK_PIPE_R, pp);
    return n;
}
static int fd_read(int fd, char *buf, int n)
{
    struct ofd *o = fd_get(fd);
    if (!o) return -EBADF;
    if (n < 0) return -EINVAL;
    switch (o->type) {
    case OT_TTY: return term_read(buf, n, o->flags & 0x800);
    case OT_FILE: if ((o->flags & 3) == 1) return -EBADF; return rw_file(o, buf, n, 0);
    case OT_DIR: return -EISDIR;
    case OT_NULL: return 0;
    case OT_ZERO: memset(buf, 0, n); return n;
    case OT_RANDOM: { int i; for (i = 0; i < n; i++) buf[i] = (millis() * 1103515245u + i * 12345u) >> 16; return n; }
    case OT_PIPE_R: return pipe_read(o->pipe, buf, n);
    case OT_TEXT: { int k = o->tlen - (int)o->pos; if (k > n) k = n; if (k < 0) k = 0; memcpy(buf, o->text + o->pos, k); o->pos += k; return k; }
    }
    return -EBADF;
}
static int fd_write(int fd, const char *buf, int n)
{
    struct ofd *o = fd_get(fd);
    if (!o) return -EBADF;
    if (n < 0) return -EINVAL;
    switch (o->type) {
    case OT_TTY: term_write((const unsigned char *)buf, n); return n;
    case OT_FILE: if ((o->flags & 3) == 0) return -EBADF; return rw_file(o, (void *)buf, n, 1);
    case OT_NULL: case OT_ZERO: case OT_RANDOM: return n;
    case OT_PIPE_W: { int k = pipe_write(o->pipe, buf, n); if (k == -EPIPE) P->pending |= 1u << 13; return k; }
    }
    return -EBADF;
}
static int fd_close(int fd)
{
    struct ofd *o = fd_get(fd);
    if (!o) return -EBADF;
    P->fd[fd].o = 0;
    ofd_put(o);
    return 0;
}
static int stat_path(const char *p, int form, unsigned char *buf)
{
    struct lxstat st;
    if (dev_kind(p)) {
        int tty = !strcmp(dev_kind(p), "/dev/tty");
        fill_any(form, buf, 020666, 0, 1000, boot_epoch, tty ? 0x8801 : 0x103);
        return 0;
    }
    {
        int len;
        char *t = made_text(p, &len);
        if (t) { fill_any(form, buf, 0100444, len, 1001, boot_epoch, 0); free(t); return 0; }
    }
    if (vstat(p, &st)) return -ENOENT;
    fill_any(form, buf, file_mode(p, &st), st.size, st.slot + 2, stamp_epoch(st.mtime), 0);
    return 0;
}
static int stat_fd(int fd, int form, unsigned char *buf)
{
    struct ofd *o = fd_get(fd);
    if (!o) return -EBADF;
    switch (o->type) {
    case OT_TTY: fill_any(form, buf, 020620, 0, 1002, boot_epoch, 0x8801); return 0;
    case OT_PIPE_R: case OT_PIPE_W: fill_any(form, buf, 010600, 0, 1003, boot_epoch, 0); return 0;
    case OT_NULL: case OT_ZERO: case OT_RANDOM: fill_any(form, buf, 020666, 0, 1004, boot_epoch, 0x103); return 0;
    case OT_TEXT: fill_any(form, buf, 0100444, o->tlen, 1005, boot_epoch, 0); return 0;
    case OT_FILE: {
        int r = stat_path(o->path, form, buf);
        if (!r && o->handle >= 0) {                       /* (its size as it is now) */
            unsigned s = fsize(o->handle);
            if (form == SF_64) *(unsigned *)(buf + 44) = s;
            else if (form == SF_OLD) *(unsigned *)(buf + 20) = s;
            else *(unsigned *)(buf + 40) = s;
        }
        return r;
    }
    case OT_DIR: return stat_path(o->path, form, buf);
    }
    return -EBADF;
}
static int do_open(const char *p, int flags, int mode)
{
    struct ofd *o;
    struct lxstat st;
    int acc = flags & 3, r, h;
    const char *dk = dev_kind(p);
    (void)mode;
    if (dk) {
        int t = !strcmp(dk, "/dev/null") || !strcmp(dk, "/dev/full") ? OT_NULL : !strcmp(dk, "/dev/zero") ? OT_ZERO :
                !strcmp(dk, "/dev/urandom") || !strcmp(dk, "/dev/random") ? OT_RANDOM : OT_TTY;
        if (!strcmp(dk, "/dev/stdin") || !strcmp(dk, "/dev/stdout") || !strcmp(dk, "/dev/stderr")) {
            int which = dk[5] == 'i' ? 0 : dk[8] == 'o' ? 1 : 2;
            struct ofd *s = fd_get(which);
            if (s) { s->refs++; return fd_new(s, 0); }
        }
        if (starts_with(p, "/proc/self/fd/")) {
            struct ofd *s = fd_get(atoi(p + 14));
            if (s) { s->refs++; return fd_new(s, 0); }
        }
        o = ofd_new(t);
        if (!o) return -ENOMEM;
        o->flags = flags;
        scopy(o->path, p, sizeof o->path);
        if ((r = fd_new(o, 0)) < 0) ofd_put(o);
        return r;
    }
    {
        int len;
        char *t = made_text(p, &len);
        if (t) {
            if (acc) { free(t); return -EACCES; }
            o = ofd_new(OT_TEXT);
            if (!o) { free(t); return -ENOMEM; }
            o->text = t; o->tlen = len;
            scopy(o->path, p, sizeof o->path);
            if ((r = fd_new(o, 0)) < 0) ofd_put(o);
            return r;
        }
    }
    r = vstat(p, &st);
    if (!r && (flags & 0xC0) == 0xC0) return -EEXIST;     /* O_CREAT | O_EXCL */
    if (!r && st.type == 2) {
        if (acc) return -EISDIR;
        o = ofd_new(OT_DIR);
        if (!o) return -ENOMEM;
        scopy(o->path, p, sizeof o->path);
        o->flags = flags;
        if ((r = fd_new(o, 0)) < 0) ofd_put(o);
        return r;
    }
    if (flags & 0x10000) return r ? -ENOENT : -ENOTDIR;  /* O_DIRECTORY */
    if (r && !(flags & 0x40)) return -ENOENT;
    if (!r && st.slot == -3) {                            /* /bin/<applet>: BusyBox itself */
        p = busybox_path;
    }
    if (strlen(p) > 120) return -ENAMETOOLONG;
    if (acc == 0) h = open(p, O_READ);
    else if (r || (flags & 0x200)) {                      /* new, or O_TRUNC: made empty */
        if (!r && (st.attr & 1)) return -EACCES;
        h = open(p, O_WRITE);
        if (h >= 0 && acc == 2) { close(h); h = open(p, O_UPDATE); }
    } else if (flags & 0x400) h = open(p, O_APPEND);
    else {
        if (st.attr & 1) return -EACCES;
        h = open(p, O_UPDATE);
    }
    if (h < 0) {
        if (r) {                                          /* (its folder isn't there?) */
            char d[160];
            int k;
            scopy(d, p, sizeof d);
            for (k = strlen(d); k > 0 && d[k] != '/'; k--) ;
            d[k ? k : 1] = 0;
            if (vstat(d, &st)) return -ENOENT;
            return -EACCES;
        }
        return -ENFILE;
    }
    o = ofd_new(OT_FILE);
    if (!o) { close(h); return -ENOMEM; }
    o->handle = h; o->flags = flags;
    o->pos = (flags & 0x400) ? (unsigned)fsize(h) : 0;
    scopy(o->path, p, sizeof o->path);
    if ((r = fd_new(o, 0)) < 0) { ofd_put(o); return r; }
    if (flags & 0x80000) P->fd[r].cloexec = 1;
    return r;
}
static int do_getdents(int fd, unsigned char *buf, int n, int is64)
{
    struct ofd *o = fd_get(fd);
    int k = 0;
    if (!o) return -EBADF;
    if (o->type != OT_DIR) return -ENOTDIR;
    for (;;) {
        static struct { char name[64]; int type; unsigned size; unsigned char time[8]; char sname[16]; } e;
        char nm[200];
        int typ, len, rec;
        unsigned ino;
        if (o->dirpos == 0) { strcpy(nm, "."); typ = 4; ino = 1; }
        else if (o->dirpos == 1) { strcpy(nm, ".."); typ = 4; ino = 1; }
        else {
            if (lx_syscall3(46, (int)o->path, o->dirpos - 2, (int)&e) < 0) break;
            to_utf(nm, e.name, sizeof nm);
            typ = e.type == 2 ? 4 : 8;
            ino = o->dirpos + 1;
        }
        len = strlen(nm);
        rec = is64 ? (19 + len + 1 + 7) & ~7 : (10 + len + 2 + 3) & ~3;
        if (k + rec > n) { if (!k) return -EINVAL; break; }
        memset(buf + k, 0, rec);
        if (is64) {
            *(unsigned *)(buf + k) = ino;
            *(unsigned *)(buf + k + 8) = o->dirpos + 1;
            *(unsigned short *)(buf + k + 16) = rec;
            buf[k + 18] = typ;
            memcpy(buf + k + 19, nm, len);
        } else {
            *(unsigned *)(buf + k) = ino;
            *(unsigned *)(buf + k + 4) = o->dirpos + 1;
            *(unsigned short *)(buf + k + 8) = rec;
            memcpy(buf + k + 10, nm, len);
            buf[k + rec - 1] = typ;
        }
        k += rec;
        o->dirpos++;
    }
    return k;
}
static int do_unlink(const char *p, int dir)
{
    struct lxstat st;
    int r;
    if (vstat(p, &st)) return -ENOENT;
    if (dir) {
        if (st.type != 2) return -ENOTDIR;
        r = lx_op(LXO_RMDIR, (int)p, 0);
        return r == -2 ? -ENOTEMPTY : r ? -EACCES : 0;
    }
    if (st.type == 2) return -EISDIR;
    if (st.slot < 0) return -EACCES;
    return lx_op(LXO_UNLINK, (int)p, 0) ? -EACCES : 0;
}
static int do_mkdir(const char *p)
{
    struct lxstat st;
    if (!vstat(p, &st)) return -EEXIST;
    if (strlen(p) > 118) return -ENAMETOOLONG;
    return mkdir(p) ? -ENOENT : 0;
}
/* rename: a file copied, then the old one deleted (LexOS has no rename
 * for a program to call); a folder: EXDEV (mv copies it itself) */
static int do_rename(const char *a, const char *b)
{
    struct lxstat sa, sb;
    int h1, h2, got;
    static char buf[16384];
    if (vstat(a, &sa)) return -ENOENT;
    if (!strcmp(a, b)) return 0;
    if (sa.type == 2) return -EXDEV;
    if (!vstat(b, &sb)) { if (sb.type == 2) return -EISDIR; lx_op(LXO_UNLINK, (int)b, 0); }
    if ((h1 = open(a, O_READ)) < 0) return -EACCES;
    if ((h2 = open(b, O_WRITE)) < 0) { close(h1); return -EACCES; }
    while ((got = read(h1, buf, sizeof buf)) > 0) if (fwrite(h2, buf, got) != got) { close(h1); close(h2); return -ENOSPC; }
    close(h1); close(h2);
    lx_op(LXO_UNLINK, (int)a, 0);
    return 0;
}

/* poll()'s and select()'s: which fds are ready to be read */
static int fd_readable(int fd)
{
    struct ofd *o = fd_get(fd);
    if (!o) return 0;
    if (o->type == OT_TTY) {
        keys_poll();
        return in_n > 0 || line_ready || interrupted;
    }
    return 1;
}
static int do_poll(unsigned char *fds, int n, int timeout)
{
    unsigned until = millis() + (timeout > 0 ? timeout : 0);
    for (;;) {
        int i, ready = 0;
        for (i = 0; i < n; i++) {
            int fd = *(int *)(fds + i * 8);
            short ev = *(short *)(fds + i * 8 + 4), rev = 0;
            if (fd >= 0) {
                if (!fd_get(fd)) rev = 0x20;              /* POLLNVAL */
                else {
                    if ((ev & 1) && fd_readable(fd)) rev |= 1;
                    if (ev & 4) rev |= 4;
                }
            }
            *(short *)(fds + i * 8 + 6) = rev;
            if (rev) ready++;
        }
        if (ready || !timeout) return ready;
        if (interrupted) return -EINTR;
        if (timeout > 0 && (int)(until - millis()) <= 0) return 0;
        flush_screen();
        sleep_ms(10);
    }
}
static int do_select(int n, unsigned *rd, unsigned *wr, unsigned *ex, int timeout)
{
    unsigned until = millis() + (timeout > 0 ? timeout : 0);
    unsigned r0[2] = { rd ? rd[0] : 0, rd && n > 32 ? rd[1] : 0 }, w0[2] = { wr ? wr[0] : 0, wr && n > 32 ? wr[1] : 0 };
    if (n > 64) n = 64;
    for (;;) {
        int i, ready = 0;
        unsigned r1[2] = { 0, 0 }, w1[2] = { 0, 0 };
        for (i = 0; i < n; i++) {
            if ((r0[i / 32] >> (i & 31) & 1) && fd_readable(i)) { r1[i / 32] |= 1u << (i & 31); ready++; }
            if ((w0[i / 32] >> (i & 31) & 1) && fd_get(i)) { w1[i / 32] |= 1u << (i & 31); ready++; }
        }
        if (ready || !timeout || interrupted || (timeout > 0 && (int)(until - millis()) <= 0)) {
            if (rd) { rd[0] = r1[0]; if (n > 32) rd[1] = r1[1]; }
            if (wr) { wr[0] = w1[0]; if (n > 32) wr[1] = w1[1]; }
            if (ex) { ex[0] = 0; if (n > 32) ex[1] = 0; }
            return interrupted && !ready ? -EINTR : ready;
        }
        flush_screen();
        sleep_ms(10);
    }
}
static int sleep_for(unsigned sec, unsigned nsec)
{
    unsigned ms = sec * 1000 + nsec / 1000000, until = millis() + ms;
    flush_screen();
    while ((int)(until - millis()) > 0) {
        unsigned left = until - millis();
        sleep_ms(left > 50 ? 50 : left);
        if (tio.lflag & ISIG) { keys_poll(); if (interrupted) return -EINTR; }
    }
    return 0;
}
static int do_ioctl(int fd, unsigned req, unsigned arg)
{
    struct ofd *o = fd_get(fd);
    if (!o) return -EBADF;
    if (o->type != OT_TTY) return req == 0x541B ? (*(int *)arg = 0, 0) : -ENOTTY;
    switch (req) {
    case 0x5401: memcpy((void *)arg, &tio, sizeof tio); return 0;                /* TCGETS */
    case 0x5402: case 0x5403: case 0x5404:                                       /* TCSETS* */
        memcpy(&tio, (void *)arg, sizeof tio);
        if (req == 0x5404) { in_n = 0; line_n = 0; line_ready = 0; }
        return 0;
    case 0x5413: { unsigned short *w = (unsigned short *)arg; w[0] = ROWS; w[1] = COLS; w[2] = w[3] = 0; return 0; }
    case 0x5414: return 0;
    case 0x540F: *(int *)arg = P->pid; return 0;                                 /* TIOCGPGRP */
    case 0x5410: return 0;                                                       /* TIOCSPGRP */
    case 0x5429: *(int *)arg = 1; return 0;                                      /* TIOCGSID */
    case 0x541B: keys_poll(); *(int *)arg = in_n + (line_ready ? line_n : 0); return 0;   /* FIONREAD */
    case 0x540E: case 0x5422: case 0x540B: case 0x5409: case 0x540A: return 0;  /* TIOCSCTTY, TIOCNOTTY, flush... */
    case 0x5421: return 0;                                                       /* FIONBIO */
    }
    return -EINVAL;
}
static int sys_fcntl(int fd, int cmd, unsigned arg)
{
    struct ofd *o = fd_get(fd);
    if (!o) return -EBADF;
    switch (cmd) {
    case 0: case 1030: { int r = fd_new(o, arg); if (r >= 0) { o->refs++; P->fd[r].cloexec = cmd == 1030; } return r; }
    case 1: return P->fd[fd].cloexec;
    case 2: P->fd[fd].cloexec = arg & 1; return 0;
    case 3: return o->flags | (o->type == OT_TTY ? 2 : 0);
    case 4: o->flags = (o->flags & ~0x800) | (arg & 0x800); return 0;
    case 5: case 6: case 7: case 12: case 13: case 14: return 0;               /* locks: always granted */
    }
    return -EINVAL;
}
static int do_dup2(int a, int b)
{
    struct ofd *o = fd_get(a);
    if (!o) return -EBADF;
    if (b < 0 || b >= NFD) return -EBADF;
    if (a == b) return b;
    if (P->fd[b].o) fd_close(b);
    P->fd[b].o = o; P->fd[b].cloexec = 0;
    o->refs++;
    return b;
}
static int do_pipe(int *fds, int flags)
{
    struct pipe *pp = malloc(sizeof *pp);
    struct ofd *r, *w;
    int a, b;
    if (!pp) return -ENOMEM;
    memset(pp, 0, sizeof *pp);
    r = ofd_new(OT_PIPE_R); w = ofd_new(OT_PIPE_W);
    if (!r || !w) return -ENOMEM;
    r->pipe = w->pipe = pp;
    pp->readers = pp->writers = 1;
    if ((a = fd_new(r, 0)) < 0) { ofd_put(r); ofd_put(w); return a; }
    if ((b = fd_new(w, 0)) < 0) { fd_close(a); ofd_put(w); return b; }
    if (flags & 0x80000) P->fd[a].cloexec = P->fd[b].cloexec = 1;
    fds[0] = a; fds[1] = b;
    return 0;
}

/* ---- processes taking turns ---- */
static void tls_apply(struct proc *p)
{
    if (p->tls_on) lx_op(LXO_TLS, p->tls_base, p->tls_lim);
}
/* the one running: its memory put aside (F: its registers) */
static int switch_out(void)
{
    struct proc *p = P;
    int i;
    p->regs = F;
    p->rw_len = p->brk > p->rw_lo ? p->brk - p->rw_lo : 0;
    p->rw = p->rw_len ? malloc(p->rw_len) : 0;
    if (F.esp >= (unsigned)stack_mem + 4096 && F.esp <= stack_top) p->stk_lo = (F.esp - 4096) & ~15u;
    else p->stk_lo = (unsigned)stack_mem;
    p->stk_len = stack_top - p->stk_lo;
    p->stk = malloc(p->stk_len);
    if ((p->rw_len && !p->rw) || !p->stk) { free(p->rw); free(p->stk); p->rw = p->stk = 0; return -ENOMEM; }
    if (p->rw_len) memcpy(p->rw, (void *)p->rw_lo, p->rw_len);
    memcpy(p->stk, (void *)p->stk_lo, p->stk_len);
    for (i = 0; i < nmaps; i++)
        if ((maps[i].seen >> cur & 1) && (maps[i].seen & ~(1u << cur))) {   /* (shared ones: its bytes) */
            free(maps[i].save[cur]);
            maps[i].save[cur] = malloc(maps[i].len);
            if (maps[i].save[cur]) memcpy(maps[i].save[cur], (void *)maps[i].addr, maps[i].len);
        }
    return 0;
}
/* its program's code, read from its file again (another's was there) */
static void load_code(struct proc *q)
{
    int h = open(q->exe, O_READ), i;
    if (h < 0) return;
    for (i = 0; i < q->nro; i++) { seek(h, q->ro[i].off); read(h, (void *)q->ro[i].vaddr, q->ro[i].filesz); }
    close(h);
    scopy(win_exe, q->exe, sizeof win_exe);
}
/* process k's turn: its memory back, on from where it was */
static void run(int k)
{
    struct proc *q = &procs[k];
    int i, was_blocked = q->state == PS_BLOCKED;
    win_need(q->brk + 4096);
    if (strcmp(win_exe, q->exe)) load_code(q);
    if (q->rw) { memcpy((void *)q->rw_lo, q->rw, q->rw_len); free(q->rw); q->rw = 0; }
    if (q->stk) { memcpy((void *)q->stk_lo, q->stk, q->stk_len); free(q->stk); q->stk = 0; }
    for (i = 0; i < nmaps; i++)
        if ((maps[i].seen >> k & 1) && maps[i].save[k]) { memcpy((void *)maps[i].addr, maps[i].save[k], maps[i].len); free(maps[i].save[k]); maps[i].save[k] = 0; }
    cur = k;
    q->state = PS_RUN;
    q->bk = 0;
    F = q->regs;
    tls_apply(q);
    if (was_blocked && (q->pending & ~q->blocked)) {      /* (a signal for it: its call's interrupted) */
        F.eip += 2;
        F.eax = -EINTR;
        deliver(0, -EINTR);
    }
    resume();
}
/* the next one to run (not the running one): `prefer` if it can */
static int pick(int prefer)
{
    int i;
    if (prefer >= 0 && prefer != cur && procs[prefer].state == PS_READY) return prefer;
    for (i = NPROC - 1; i >= 0; i--) if (i != cur && procs[i].state == PS_READY) return i;
    return -1;
}
static void wake(int kind, void *on)
{
    int i;
    for (i = 0; i < NPROC; i++)
        if (procs[i].state == PS_BLOCKED && procs[i].bk == kind && procs[i].bk_on == on) procs[i].state = PS_READY;
}
/* the running process has to wait (for a pipe, a child): another one
 * runs, and this call's made again when it's woken. Returns only if
 * there's nobody else to run (the call then does what it can). */
static int block(int kind, void *on)
{
    int k;
    if (P->noblock) { P->noblock = 0; return 0; }
    if ((k = pick(-1)) < 0) return 0;
    F.eip -= 2;                                           /* (int 0x80 again, eax still its number) */
    P->state = PS_BLOCKED; P->bk = kind; P->bk_on = on;
    if (switch_out()) { F.eip += 2; P->state = PS_RUN; return 0; }
    run(k);
    return 0;
}
static int do_fork(unsigned flags, unsigned ctid)
{
    struct proc *par = P, *ch;
    int i, c;
    for (c = 0; c < NPROC; c++) if (procs[c].state == PS_FREE) break;
    if (c == NPROC) return -EAGAIN;
    ch = &procs[c];
    *ch = *par;
    ch->pid = next_pid++;
    ch->ppid = par->pid;
    ch->pending = 0;
    ch->state = PS_RUN;
    ch->rw = ch->stk = 0;
    for (i = 0; i < nmaps; i++) if (maps[i].seen >> cur & 1) maps[i].seen |= 1u << c;
    F.eax = ch->pid;                                      /* (the parent's answer, for later) */
    if (switch_out()) {
        for (i = nmaps - 1; i >= 0; i--) if (maps[i].seen >> c & 1) map_unsee(i, c);
        ch->state = PS_FREE;
        return -ENOMEM;
    }
    par->state = PS_READY;
    for (i = 0; i < NFD; i++) if (ch->fd[i].o) ch->fd[i].o->refs++;
    cur = c;
    if ((flags & 0x01000000) && ctid) *(int *)ctid = ch->pid;   /* CLONE_CHILD_SETTID */
    return 0;                                             /* (the child's answer) */
}
static void proc_exit(int status)
{
    struct proc *p = P;
    int i, par = -1, k;
    flush_screen();
    if (p->pid == 100) exit(status >> 8 & 255 ? status >> 8 & 255 : status & 127 ? 128 + (status & 127) : 0);
    for (i = 0; i < NFD; i++) if (p->fd[i].o) { ofd_put(p->fd[i].o); p->fd[i].o = 0; }
    maps_unsee_all(cur);
    for (i = 0; i < NPROC; i++) {                         /* its children: nobody's now */
        if (procs[i].state == PS_FREE || procs[i].ppid != p->pid || i == cur) continue;
        if (procs[i].state == PS_ZOMBIE) procs[i].state = PS_FREE; else procs[i].ppid = 1;
    }
    for (i = 0; i < NPROC; i++) if (procs[i].state != PS_FREE && procs[i].state != PS_ZOMBIE && procs[i].pid == p->ppid) par = i;
    p->status = status;
    p->state = par >= 0 ? PS_ZOMBIE : PS_FREE;
    if (par >= 0) {
        procs[par].pending |= 1u << 17;                   /* SIGCHLD */
        if (procs[par].state == PS_BLOCKED && procs[par].bk == BK_WAIT) procs[par].state = PS_READY;
    }
    k = pick(par);
    if (k < 0) {                                          /* everyone's waiting: one of them, */
        for (i = NPROC - 1; i >= 0 && k < 0; i--)         /* told not to */
            if (procs[i].state == PS_BLOCKED) { k = i; procs[i].state = PS_READY; procs[i].noblock = 1; }
    }
    if (k < 0) exit(0);
    run(k);
}
static int do_wait(int pid, int *status, int options)
{
    int i, live = 0;
    for (;;) {
        for (i = 0; i < NPROC; i++) {
            struct proc *c = &procs[i];
            if (c->state == PS_FREE || c->ppid != P->pid || i == cur) continue;
            if (!(pid == -1 || pid == 0 || pid == c->pid || pid < -1)) continue;
            if (c->state == PS_ZOMBIE) {
                if (status) *status = c->status;
                c->state = PS_FREE;
                return c->pid;
            }
            live = 1;
        }
        if (!live) return -ECHILD;
        if (options & 1) return 0;                        /* WNOHANG */
        if (pick(-1) < 0)                                 /* (its children all waiting: one of them, */
            for (i = NPROC - 1; i >= 0; i--)              /*  told not to) */
                if (procs[i].state == PS_BLOCKED && procs[i].ppid == P->pid) { procs[i].state = PS_READY; procs[i].noblock = 1; break; }
        block(BK_WAIT, 0);
        return -ECHILD;                                   /* (nobody could run: none will end) */
    }
}

/* ---- execve ---- */
static char *dup_strs(char **v, char ***out)            /* argv/envp copied out of the old program */
{
    int n = 0, len = 0, i;
    char *mem, *q, **arr;
    if (v) while (v[n] && n < 255) { len += strlen(v[n]) + 1; n++; }
    mem = malloc(len + (n + 1) * sizeof(char *) + 1);
    if (!mem) return 0;
    arr = (char **)mem;
    q = mem + (n + 1) * sizeof(char *);
    for (i = 0; i < n; i++) { arr[i] = q; q = stpcopy(q, v[i]) + 1; }
    arr[n] = 0;
    *out = arr;
    return mem;
}
static int exec_path(const char *p, char **argv, char **envp, int *used_busybox)
{
    struct lxstat st;
    const char *real = p;
    int h, r;
    *used_busybox = 0;
    if (vstat(p, &st)) return -ENOENT;
    if (st.type == 2) return -EACCES;
    if (st.slot == -3) { real = busybox_path; *used_busybox = 1; }
    if ((h = open(real, O_READ)) < 0) return -EACCES;
    {
        unsigned char m[4];
        if (read(h, m, 4) != 4 || memcmp(m, "\177ELF", 4)) {
            close(h);
            if (m[0] == '#' && m[1] == '!') return -ENOEXEC;   /* (a script: the shell runs it itself) */
            return -ENOEXEC;
        }
    }
    maps_unsee_all(cur);                                  /* (the point of no return) */
    to_utf(exe_name, real, sizeof exe_name);
    scopy(P->exe, real, sizeof P->exe);
    r = load_elf(h);
    if (!r && !busybox_known && same_ci(base_name(real), "busybox")) note_busybox(real, h);
    close(h);
    if (r) {
        char t[200];
        char *q = stpcopy(t, "\nLINUX.APP: can't run ");
        q = stpcopy(q, exe_name); q = stpcopy(q, ": "); q = stpcopy(q, load_err); q = stpcopy(q, "\n");
        term_write((unsigned char *)t, q - t);
        proc_exit(127 << 8);
    }
    P->tls_on = 0;
    {
        int i;
        for (i = 1; i < 65; i++) if (P->sa[i].handler != 1) memset(&P->sa[i], 0, sizeof P->sa[i]);
        P->nsig = 0;
    }
    {
        int i;
        for (i = 0; i < NFD; i++) if (P->fd[i].o && P->fd[i].cloexec) fd_close(i);
    }
    memset(&F, 0, sizeof F);
    F.esp = build_stack(argv, envp);
    F.eip = auxv_entry;
    F.eflags = 0x202;
    return 0;
}
static int do_execve(const char *upath, char **uargv, char **uenvp)
{
    char p[160], **argv, **envp, *m1, *m2;
    int r, bb;
    if ((r = path_at(-100, upath, p, sizeof p))) return r;
    m1 = dup_strs(uargv, &argv);
    m2 = dup_strs(uenvp, &envp);
    if (!m1 || !m2) { free(m1); free(m2); return -ENOMEM; }
    r = exec_path(p, argv, envp, &bb);
    free(m1); free(m2);
    if (r) return r;
    resume();
    return 0;
}

/* ---- signals: one of the program's own (raise, kill to itself), Ctrl+C
 * (SIGINT), a child's end (SIGCHLD), a pipe nobody reads (SIGPIPE) -
 * to its handler (a frame on its stack, back through sigreturn), or
 * its default: most end the process ---- */
static void deliver(unsigned nr, int r)
{
    int sig;
    if (interrupted) {                                    /* Ctrl+C */
        interrupted = 0;
        P->pending |= 1u << 2;
        if (tio.lflag & ECHO) term_write((const unsigned char *)"^C", 2);
    }
    for (sig = 1; sig < 32; sig++) {
        struct sigact *sa;
        unsigned sp, info, uc, ret, *f;
        if (!(P->pending & ~P->blocked & (1u << sig))) continue;
        P->pending &= ~(1u << sig);
        sa = &P->sa[sig];
        if (sa->handler == 1) continue;                   /* SIG_IGN */
        if (sa->handler == 0) {                           /* SIG_DFL */
            if (sig == 17 || sig == 28 || sig == 23 || sig == 18 || (sig >= 19 && sig <= 22)) continue;
            if (sig == 2) term_write((const unsigned char *)"\n", 1);
            if (sig == 6) term_write((const unsigned char *)"Aborted\n", 8);
            proc_exit(sig);
        }
        if (P->nsig >= 8) return;
        if (r == -EINTR && nr) {                          /* a call it interrupted: again, or EINTR */
            if (sa->flags & 0x10000000) { F.eax = nr; F.eip -= 2; }
        }
        P->sigsave[P->nsig] = F;
        P->sigmask_save[P->nsig] = P->blocked;
        P->nsig++;
        sp = (F.esp - 256) & ~15u;
        sp -= 8; memcpy((void *)sp, "\xb8\xad\x00\x00\x00\xcd\x80\x90", 8); ret = sp;
        sp -= 256; uc = sp; memset((void *)uc, 0, 256);
        sp -= 128; info = sp; memset((void *)info, 0, 128); *(int *)info = sig;
        sp = ((sp - 16) & ~15u) - 4;
        f = (unsigned *)sp;
        f[0] = (sa->flags & 0x04000000) && sa->restorer ? sa->restorer : ret;
        f[1] = sig; f[2] = info; f[3] = uc;
        F.esp = sp; F.eip = sa->handler; F.eax = sig; F.edx = info; F.ecx = uc;
        if (!(sa->flags & 0x40000000)) P->blocked |= 1u << sig;
        P->blocked |= sa->mask[0];
        if (sa->flags & 0x80000000) sa->handler = 0;
        return;
    }
}

/* ---- the call itself ---- */
static unsigned sysinfo_buf[16];
static int calls;
void lx_handle(void)
{
    unsigned nr = F.eax, a = F.ebx, b = F.ecx, c = F.edx, d = F.esi, e = F.edi;
    int r = -ENOSYS;
    char p[160], p2[160];
    if ((++calls & 31) == 0 && (tio.lflag & ISIG)) keys_poll();   /* (Ctrl+C, now and then) */
    switch (nr) {
    case 1: case 252: proc_exit((a & 255) << 8); break;                         /* exit, exit_group */
    case 3: r = fd_read(a, (char *)b, c); break;                                /* read */
    case 4: r = fd_write(a, (const char *)b, c); break;                         /* write */
    case 5: r = path_at(-100, (char *)a, p, sizeof p); if (!r) r = do_open(p, b, c); break;    /* open */
    case 295: r = path_at(a, (char *)b, p, sizeof p); if (!r) r = do_open(p, c, d); break;    /* openat */
    case 8: r = path_at(-100, (char *)a, p, sizeof p); if (!r) r = do_open(p, 0x241, b); break; /* creat */
    case 6: r = fd_close(a); break;                                             /* close */
    case 19: {                                                                  /* lseek */
        struct ofd *o = fd_get(a);
        int pos;
        if (!o) { r = -EBADF; break; }
        if (o->type == OT_TTY || o->type == OT_PIPE_R || o->type == OT_PIPE_W) { r = -ESPIPE; break; }
        if (o->type == OT_DIR) { if (!b && !c) o->dirpos = 0; r = 0; break; }
        pos = c == 0 ? (int)b : c == 1 ? (int)o->pos + (int)b : (o->type == OT_FILE ? fsize(o->handle) : o->tlen) + (int)b;
        if (pos < 0) { r = -EINVAL; break; }
        o->pos = pos; r = pos;
        break;
    }
    case 140: {                                                                 /* _llseek */
        struct ofd *o = fd_get(a);
        int pos;
        if (!o) { r = -EBADF; break; }
        if (o->type == OT_TTY || o->type == OT_PIPE_R || o->type == OT_PIPE_W) { r = -ESPIPE; break; }
        if (o->type == OT_DIR) { if (!c) o->dirpos = 0; *(unsigned *)d = 0; *(unsigned *)(d + 4) = 0; r = 0; break; }
        pos = e == 0 ? (int)c : e == 1 ? (int)o->pos + (int)c : (o->type == OT_FILE ? fsize(o->handle) : o->tlen) + (int)c;
        if (pos < 0) { r = -EINVAL; break; }
        o->pos = pos;
        *(unsigned *)d = pos; *(unsigned *)(d + 4) = 0;
        r = 0;
        break;
    }
    case 180: case 181: {                                                       /* pread64, pwrite64 */
        struct ofd *o = fd_get(a);
        unsigned keep;
        if (!o || o->type != OT_FILE) { r = o ? -ESPIPE : -EBADF; break; }
        keep = o->pos; o->pos = d;
        r = nr == 180 ? fd_read(a, (char *)b, c) : fd_write(a, (char *)b, c);
        o->pos = keep;
        break;
    }
    case 145: case 146: {                                                       /* readv, writev */
        unsigned *iov = (unsigned *)b;
        int i, tot = 0;
        for (i = 0; i < (int)c; i++) {
            int k;
            if (!iov[i * 2 + 1]) continue;
            k = nr == 145 ? fd_read(a, (char *)iov[i * 2], iov[i * 2 + 1]) : fd_write(a, (char *)iov[i * 2], iov[i * 2 + 1]);
            if (k < 0) { if (!tot) tot = k; break; }
            tot += k;
            if (k < (int)iov[i * 2 + 1]) break;
        }
        r = tot;
        break;
    }
    case 187: case 239: {                                                       /* sendfile */
        static char buf[8192];
        int tot = 0;
        unsigned *off = (unsigned *)c;
        struct ofd *in = fd_get(b);
        unsigned keep = in ? in->pos : 0;
        if (!in || !fd_get(a)) { r = -EBADF; break; }               /* (nothing read before that's known) */
        if (off) in->pos = *off;
        while (tot < (int)d) {
            int want = (int)d - tot > (int)sizeof buf ? (int)sizeof buf : (int)d - tot, k = fd_read(b, buf, want), w;
            if (k <= 0) { if (k < 0 && !tot) tot = k; break; }
            w = fd_write(a, buf, k);
            if (w < 0) { if (!tot) tot = w; break; }
            tot += w;
        }
        if (off) { *off = in->pos; in->pos = keep; }
        r = tot;
        break;
    }
    case 106: case 107: case 195: case 196:                                     /* stat, lstat, stat64, lstat64 */
        r = path_at(-100, (char *)a, p, sizeof p);
        if (!r) r = stat_path(p, nr >= 195 ? SF_64 : SF_OLD, (unsigned char *)b);
        break;
    case 108: case 197: r = stat_fd(a, nr == 197 ? SF_64 : SF_OLD, (unsigned char *)b); break;   /* fstat, fstat64 */
    case 300:                                                                   /* fstatat64 */
        if ((d & 0x1000) && !*(char *)b) { r = stat_fd(a, SF_64, (unsigned char *)c); break; }
        r = path_at(a, (char *)b, p, sizeof p);
        if (!r) r = stat_path(p, SF_64, (unsigned char *)c);
        break;
    case 383:                                                                   /* statx */
        if ((c & 0x1000) && !*(char *)b) { r = stat_fd(a, SF_X, (unsigned char *)e); break; }
        r = path_at(a, (char *)b, p, sizeof p);
        if (!r) r = stat_path(p, SF_X, (unsigned char *)e);
        break;
    case 141: r = do_getdents(a, (unsigned char *)b, c, 0); break;
    case 220: r = do_getdents(a, (unsigned char *)b, c, 1); break;
    case 33: case 307: case 439: {                                              /* access, faccessat(2) */
        struct lxstat st;
        r = nr == 33 ? path_at(-100, (char *)a, p, sizeof p) : path_at(a, (char *)b, p, sizeof p);
        if (r) break;
        if (dev_kind(p)) break;
        { int len; char *t = made_text(p, &len); if (t) { free(t); break; } }
        r = vstat(p, &st) ? -ENOENT : 0;
        if (!r && ((nr == 33 ? b : c) & 2) && (st.attr & 1)) r = -EACCES;
        break;
    }
    case 183: {                                                                 /* getcwd */
        char t[512];
        int l = to_utf(t, P->cwd, sizeof t);
        if ((int)b < l + 1) { r = -ERANGE; break; }
        memcpy((void *)a, t, l + 1);
        r = l + 1;
        break;
    }
    case 12: case 133: {                                                        /* chdir, fchdir */
        struct lxstat st;
        if (nr == 133) {
            struct ofd *o = fd_get(a);
            if (!o) { r = -EBADF; break; }
            if (o->type != OT_DIR) { r = -ENOTDIR; break; }
            scopy(p, o->path, sizeof p);
            r = 0;
        } else r = path_at(-100, (char *)a, p, sizeof p);
        if (r) break;
        if (vstat(p, &st)) { r = -ENOENT; break; }
        if (st.type != 2) { r = -ENOTDIR; break; }
        scopy(P->cwd, p, sizeof P->cwd);
        r = 0;
        break;
    }
    case 39: case 296:                                                          /* mkdir, mkdirat */
        r = nr == 39 ? path_at(-100, (char *)a, p, sizeof p) : path_at(a, (char *)b, p, sizeof p);
        if (!r) r = do_mkdir(p);
        break;
    case 40: r = path_at(-100, (char *)a, p, sizeof p); if (!r) r = do_unlink(p, 1); break;   /* rmdir */
    case 10: r = path_at(-100, (char *)a, p, sizeof p); if (!r) r = do_unlink(p, 0); break;   /* unlink */
    case 301: r = path_at(a, (char *)b, p, sizeof p); if (!r) r = do_unlink(p, c & 0x200); break;   /* unlinkat */
    case 38: case 302: case 353:                                                /* rename, renameat(2) */
        if (nr == 38) { r = path_at(-100, (char *)a, p, sizeof p); if (!r) r = path_at(-100, (char *)b, p2, sizeof p2); }
        else { r = path_at(a, (char *)b, p, sizeof p); if (!r) r = path_at(c, (char *)d, p2, sizeof p2); }
        if (!r) r = do_rename(p, p2);
        break;
    case 9: case 83: case 303: case 304: case 14: case 297: r = -EPERM; break;  /* links, nodes */
    case 85: case 305: {                                                        /* readlink(at) */
        char *u = nr == 85 ? (char *)a : (char *)b;
        char *out = nr == 85 ? (char *)b : (char *)c;
        int n = nr == 85 ? (int)c : (int)d, l;
        if (strcmp(u, "/proc/self/exe")) { r = -EINVAL; break; }
        l = strlen(exe_name);
        if (l > n) l = n;
        memcpy(out, exe_name, l);
        r = l;
        break;
    }
    case 92: case 193: case 93: case 194: {                                     /* truncate, ftruncate */
        if (nr == 93 || nr == 194) {
            struct ofd *o = fd_get(a);
            if (!o) { r = -EBADF; break; }
            if (o->type != OT_FILE) { r = -EINVAL; break; }
            r = lx_op(LXO_TRUNC, o->handle, b) ? -EIO : 0;
        } else {
            int h;
            r = path_at(-100, (char *)a, p, sizeof p);
            if (r) break;
            if ((h = open(p, O_UPDATE)) < 0) { r = -ENOENT; break; }
            r = lx_op(LXO_TRUNC, h, b) ? -EIO : 0;
            close(h);
        }
        break;
    }
    case 15: case 94: case 306: case 16: case 95: case 182: case 198: case 207: case 212: case 298:
    case 30: case 271: case 320: case 412: case 36: case 118: case 148: case 250: case 272:
        r = 0; break;                                                           /* chmod, chown, utime, sync, fadvise */
    case 54: r = do_ioctl(a, b, c); break;
    case 55: case 221: r = sys_fcntl(a, b, c); break;
    case 41: { struct ofd *o = fd_get(a); if (!o) { r = -EBADF; break; } r = fd_new(o, 0); if (r >= 0) o->refs++; break; }   /* dup */
    case 63: r = do_dup2(a, b); break;
    case 330: r = a == b ? -EINVAL : do_dup2(a, b); if (r >= 0 && (c & 0x80000)) P->fd[r].cloexec = 1; break;
    case 42: r = do_pipe((int *)a, 0); break;
    case 331: r = do_pipe((int *)a, b); break;
    case 45: r = sys_brk(a); break;
    case 90: { unsigned *v = (unsigned *)a; r = sys_mmap(v[0], v[1], v[2], v[3], v[4], v[5]); break; }
    case 192: r = sys_mmap(a, b, c, d, e, F.ebp * 4096); break;
    case 91: r = sys_munmap(a, b); break;
    case 125: case 219: case 150: case 151: case 152: case 153: r = 0; break;  /* mprotect, madvise, mlock */
    case 163: r = -ENOMEM; break;                                               /* mremap */
    case 243: {                                                                 /* set_thread_area */
        unsigned *u = (unsigned *)a;
        if ((int)u[0] != -1 && u[0] != 8 && u[0] != 6) { r = -EINVAL; break; }
        u[0] = 8;
        P->tls_base = u[1];
        P->tls_lim = (u[2] & 0xFFFFF) | ((u[3] >> 4 & 1) ? 0x80000000u : 0);
        P->tls_on = 1;
        tls_apply(P);
        r = 0;
        break;
    }
    case 244: r = -EINVAL; break;                                               /* get_thread_area */
    case 258: r = P->pid; break;                                                /* set_tid_address */
    case 311: case 312: r = 0; break;                                           /* robust lists */
    case 240: r = 0; break;                                                     /* futex */
    case 20: case 224: r = P->pid; break;                                       /* getpid, gettid */
    case 64: r = P->ppid; break;
    case 24: case 47: case 49: case 50: case 199: case 200: case 201: case 202: r = 0; break;   /* uids */
    case 23: case 46: case 213: case 214: case 203: case 204: case 208: case 210: case 164: case 170:
    case 209: case 211: case 165: case 171: case 81: case 206: r = 0; break;     /* set*id, get*res*id, groups */
    case 80: case 205: r = 0; break;                                            /* getgroups */
    case 65: case 132: r = P->pid; break;                                       /* getpgrp, getpgid */
    case 57: r = 0; break;                                                      /* setpgid */
    case 147: r = 1; break;                                                     /* getsid */
    case 66: r = P->pid; break;                                                 /* setsid */
    case 60: r = P->umask; P->umask = a & 0777; break;
    case 122: case 109: {                                                       /* uname */
        char *u = (char *)a;
        int sz = nr == 122 ? 65 : 65;
        memset(u, 0, sz * 6);
        strcpy(u, "Linux"); strcpy(u + sz, "lexos"); strcpy(u + sz * 2, "5.10.0-lexos");
        strcpy(u + sz * 3, "#1 LexOS"); strcpy(u + sz * 4, "i686"); strcpy(u + sz * 5, "(none)");
        r = 0;
        break;
    }
    case 13: r = now_sec(); if (a) *(unsigned *)a = r; break;                   /* time */
    case 78: if (a) { ((unsigned *)a)[0] = now_sec(); ((unsigned *)a)[1] = now_nsec() / 1000; }   /* gettimeofday */
             if (b) { ((int *)b)[0] = -tz_minutes; ((int *)b)[1] = 0; } r = 0; break;
    case 265: case 403: case 266: case 406: {                                   /* clock_gettime(64), getres */
        unsigned s, ns;
        if (nr == 266 || nr == 406) { s = 0; ns = 1000000; if (!b) { r = 0; break; } }
        else if (a == 0 || a == 5 || a == 8) { s = now_sec(); ns = now_nsec(); }
        else { unsigned m = millis(); s = m / 1000; ns = m % 1000 * 1000000; }
        if (nr == 403 || nr == 406) { ((unsigned *)b)[0] = s; ((unsigned *)b)[1] = 0; ((unsigned *)b)[2] = ns; ((unsigned *)b)[3] = 0; }
        else { ((unsigned *)b)[0] = s; ((unsigned *)b)[1] = ns; }
        r = 0;
        break;
    }
    case 162: r = sleep_for(((unsigned *)a)[0], ((unsigned *)a)[1]); if (r == 0 && b) memset((void *)b, 0, 8); break;
    case 267: case 407: {                                                       /* clock_nanosleep(64) */
        unsigned *t = (unsigned *)c, s = t[0], ns = nr == 407 ? t[2] : t[1];
        if (b & 1) {                                                            /* TIMER_ABSTIME */
            unsigned cur = a == 1 ? millis() / 1000 : now_sec();
            s = s > cur ? s - cur : 0;
        }
        r = sleep_for(s, ns);
        break;
    }
    case 43: if (a) memset((void *)a, 0, 16); r = millis() / 10; break;         /* times */
    case 77: memset((void *)b, 0, 72); r = 0; break;                            /* getrusage */
    case 116: {                                                                 /* sysinfo */
        unsigned *s = sysinfo_buf;
        memset(s, 0, sizeof sysinfo_buf);
        s[0] = millis() / 1000; s[4] = 256u << 20; s[5] = 128u << 20; s[10] = 1;
        s[13] = 1;
        memcpy((void *)a, s, 64);
        r = 0;
        break;
    }
    case 191: case 76: {                                                        /* ugetrlimit */
        unsigned *l = (unsigned *)b;
        l[0] = l[1] = a == 3 ? STACK_SIZE : a == 7 ? NFD : 0xFFFFFFFF;
        r = 0;
        break;
    }
    case 75: r = 0; break;                                                      /* setrlimit */
    case 340: {                                                                 /* prlimit64 */
        if (d) {
            unsigned *l = (unsigned *)d;
            unsigned v = b == 3 ? STACK_SIZE : b == 7 ? NFD : 0xFFFFFFFF;
            l[0] = v; l[1] = v == 0xFFFFFFFF ? 0xFFFFFFFF : 0; l[2] = v; l[3] = l[1];
        }
        r = 0;
        break;
    }
    case 355: {                                                                 /* getrandom */
        unsigned i, x = millis() * 2654435761u ^ calls;
        for (i = 0; i < b; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; ((unsigned char *)a)[i] = x; }
        r = b;
        break;
    }
    case 67: case 174: {                                                        /* sigaction */
        struct sigact *sa;
        if (a < 1 || a > 64 || a == 9 || a == 19) { r = -EINVAL; break; }
        sa = &P->sa[a];
        if (c) {
            unsigned *o = (unsigned *)c;
            if (nr == 174) { o[0] = sa->handler; o[1] = sa->flags; o[2] = sa->restorer; o[3] = sa->mask[0]; o[4] = sa->mask[1]; }
            else { o[0] = sa->handler; o[1] = sa->mask[0]; o[2] = sa->flags; o[3] = sa->restorer; }
        }
        if (b) {
            unsigned *n = (unsigned *)b;
            if (nr == 174) { sa->handler = n[0]; sa->flags = n[1]; sa->restorer = n[2]; sa->mask[0] = n[3]; sa->mask[1] = n[4]; }
            else { sa->handler = n[0]; sa->mask[0] = n[1]; sa->flags = n[2]; sa->restorer = n[3]; sa->mask[1] = 0; }
        }
        r = 0;
        break;
    }
    case 126: case 175: {                                                       /* sigprocmask */
        unsigned old = P->blocked;
        if (b) {
            unsigned m = *(unsigned *)b & ~(1u << 9 | 1u << 19);
            if (a == 0) P->blocked |= m; else if (a == 1) P->blocked &= ~m; else if (a == 2) P->blocked = m;
            else { r = -EINVAL; break; }
        }
        if (c) { ((unsigned *)c)[0] = old; if (nr == 175) ((unsigned *)c)[1] = 0; }
        r = 0;
        break;
    }
    case 73: case 176: *(unsigned *)a = P->pending; if (nr == 176) ((unsigned *)a)[1] = 0; r = 0; break;   /* sigpending */
    case 119: case 173:                                                         /* sigreturn */
        if (P->nsig > 0) { P->nsig--; F = P->sigsave[P->nsig]; P->blocked = P->sigmask_save[P->nsig]; }
        deliver(0, 0);
        resume();
        break;
    case 72: case 179: case 29: {                                               /* sigsuspend, pause */
        unsigned keep = P->blocked;
        if (nr != 29) P->blocked = *(unsigned *)(nr == 72 ? c : a);
        while (!(P->pending & ~P->blocked)) {
            flush_screen();
            if (tio.lflag & ISIG) { keys_poll(); if (interrupted) break; }
            sleep_ms(20);
        }
        r = -EINTR;
        F.eax = r;
        deliver(nr, r);
        P->blocked = keep;
        resume();
        break;
    }
    case 186: if (b) memset((void *)b, 0, 12); r = 0; break;                    /* sigaltstack */
    case 27: r = 0; break;                                                      /* alarm */
    case 48: r = 0; break;                                                      /* signal */
    case 37: case 238: case 270: {                                              /* kill, tkill, tgkill */
        int pid = nr == 270 ? (int)b : (int)a, sig = nr == 270 ? (int)c : (int)b, i;
        if (sig < 0 || sig > 31) { r = -EINVAL; break; }
        if (pid == P->pid || pid == 0 || nr != 37 || pid == -1 || pid == -P->pid) {
            if (sig) P->pending |= 1u << sig;
            r = 0;
            break;
        }
        r = -ESRCH;
        for (i = 0; i < NPROC; i++)
            if (procs[i].state != PS_FREE && (procs[i].pid == pid || -procs[i].pid == pid)) {
                if (sig && procs[i].state != PS_ZOMBIE) {
                    procs[i].pending |= 1u << sig;
                    if (procs[i].state == PS_BLOCKED) procs[i].state = PS_READY;
                }
                r = 0;
            }
        break;
    }
    case 158: case 154: case 155: case 156: case 157: case 159: case 160: r = 0; break;   /* sched_* */
    case 242: if (c) { memset((void *)c, 0, b); *(unsigned char *)c = 1; } r = 4; break;  /* sched_getaffinity */
    case 136: r = 0; break;                                                     /* personality */
    case 172: r = 0; break;                                                     /* prctl */
    case 96: r = 20; break;                                                     /* getpriority */
    case 97: case 34: r = 0; break;                                             /* setpriority, nice */
    case 99: case 100: case 268: case 269: {                                    /* statfs */
        unsigned *s = (unsigned *)(nr >= 268 ? c : b);
        memset(s, 0, nr >= 268 ? 84 : 64);
        s[0] = 0x4D44; s[1] = 4096; s[2] = 65536; s[4] = 32768; s[6] = 32768;
        if (nr >= 268) { s[2] = 65536; s[3] = 0; s[4] = 32768; s[5] = 0; s[6] = 32768; s[7] = 0; s[8] = 8192; s[10] = 4096; s[13] = 255; }
        else s[9] = 255;
        r = 0;
        break;
    }
    case 168: r = do_poll((unsigned char *)a, b, c); break;                     /* poll */
    case 309: case 414: {                                                       /* ppoll(64) */
        int t = -1;
        if (c) t = nr == 414 ? ((unsigned *)c)[0] * 1000 + ((unsigned *)c)[2] / 1000000 : ((unsigned *)c)[0] * 1000 + ((unsigned *)c)[1] / 1000000;
        r = do_poll((unsigned char *)a, b, t);
        break;
    }
    case 142: case 82: {                                                        /* select */
        int t = -1;
        unsigned *v = (unsigned *)a;
        if (nr == 82) { a = v[0]; b = v[1]; c = v[2]; d = v[3]; e = v[4]; }
        if (e) t = ((unsigned *)e)[0] * 1000 + ((unsigned *)e)[1] / 1000;
        r = do_select(a, (unsigned *)b, (unsigned *)c, (unsigned *)d, t);
        break;
    }
    case 308: case 413: {                                                       /* pselect6(64) */
        int t = -1;
        if (e) t = nr == 413 ? ((unsigned *)e)[0] * 1000 + ((unsigned *)e)[2] / 1000000 : ((unsigned *)e)[0] * 1000 + ((unsigned *)e)[1] / 1000000;
        r = do_select(a, (unsigned *)b, (unsigned *)c, (unsigned *)d, t);
        break;
    }
    case 2: r = do_fork(0, 0); break;                                           /* fork */
    case 190: r = do_fork(0, 0); break;                                         /* vfork */
    case 120:                                                                   /* clone */
        if (a & 0x10000) { r = -ENOSYS; break; }                                /* (threads: no) */
        r = do_fork(a, e);
        if (!r && b) F.esp = b;                                                 /* (the child on a stack of its own) */
        break;
    case 11: r = do_execve((char *)a, (char **)b, (char **)c); break;           /* execve */
    case 358: r = path_at(a, (char *)b, p, sizeof p); if (!r) { char t[200]; to_utf(t, p, sizeof t); r = do_execve(t, (char **)c, (char **)d); } break;
    case 114: case 7: r = do_wait(a, (int *)b, c); break;                       /* wait4, waitpid */
    case 284: {                                                                 /* waitid */
        int st = 0, pid = do_wait(b ? (int)b : -1, &st, d);
        if (pid < 0) { r = pid; break; }
        if (c) { unsigned *si = (unsigned *)c; memset(si, 0, 128); si[0] = 17; si[2] = (st & 127) ? 2 : 1; si[3] = pid; si[5] = (st & 127) ? (unsigned)(st & 127) : (unsigned)(st >> 8 & 255); }
        r = 0;
        break;
    }
    case 102: case 359: r = -EAFNOSUPPORT; break;                               /* sockets */
    case 103: case 88: case 21: case 22: case 52: r = -EPERM; break;            /* syslog, reboot, mount */
    }
    if (trace) trace_call(nr, r);
    F.eax = r;
    deliver(nr, r);
    resume();
}

/* ============================================================
 * starting: the command line -> the first Linux program
 * ============================================================ */
static char *cmdline_args(int argc, char **argv, int *n)  /* words again, quotes kept together */
{
    static char line[1024], *out[64];
    char *q = line, *s;
    int i, k = 0;
    for (i = 0; i < argc; i++) { if (i) *q++ = ' '; q = stpcopy(q, argv[i]); }
    *q = 0;
    s = line;
    while (*s && k < 63) {
        char *w, *d;
        while (*s == ' ') s++;
        if (!*s) break;
        w = d = s;
        while (*s && *s != ' ') {
            if (*s == '"' || *s == '\'') {
                char qc = *s++;
                while (*s && *s != qc) *d++ = *s++;
                if (*s) s++;
            } else *d++ = *s++;
        }
        if (*s) s++;
        *d = 0;
        out[k++] = w;
    }
    out[k] = 0;
    *n = k;
    return (char *)out;
}
int main(int argc, char **argv)
{
    static char *envp[16], tz[24], pwd[300], *largv[64];
    static struct { unsigned handler, stack, frame; } reg;
    char **words;
    int nw, h, i, r;
    struct ofd *tty;
    time_init();
    term_init();
    keymode(1);                                           /* (Ctrl+C, Ctrl+D...: the program's) */
    stack_mem = malloc(STACK_SIZE + 64);
    if (!stack_mem) { puts("LINUX.APP: no memory\n"); return 1; }
    stack_top = ((unsigned)stack_mem + STACK_SIZE) & ~15u;
    words = (char **)cmdline_args(argc, argv, &nw);
    if (nw < 1) { puts("LINUX.APP runs Linux programs: run busybox ls\n"); return 1; }
    for (i = 0; i < nw && i < 62; i++) largv[i] = words[i];
    largv[i] = 0;
    {                                                     /* argv[0]: as Linux names it (lower case) */
        char *s = largv[0];
        for (; *s; s++) *s = lower(*s);
    }
    {                                                     /* the first process */
        struct proc *p = &procs[0];
        memset(p, 0, sizeof *p);
        p->pid = 100; p->ppid = 1; p->umask = 022;
        p->state = PS_RUN;
        lx_op(LXO_CWD, (int)p->cwd, 0);
        tty = ofd_new(OT_TTY);
        tty->flags = 2;
        tty->refs = 3;
        p->fd[0].o = p->fd[1].o = p->fd[2].o = tty;
    }
    {                                                     /* the environment */
        int m = tz_minutes;
        char *q = tz;
        q = stpcopy(q, "TZ=LXT");
        if (m) { *q++ = m > 0 ? '-' : '+'; if (m < 0) m = -m; q = utoa(m / 60, q); if (m % 60) { *q++ = ':'; if (m % 60 < 10) *q++ = '0'; q = utoa(m % 60, q); } }
        else *q++ = '0';
        *q = 0;
        q = stpcopy(pwd, "PWD=");
        to_utf(q, procs[0].cwd, sizeof pwd - 4);
        envp[0] = "PATH=/bin:/usr/bin:/sbin:/usr/sbin:/LINUX";
        envp[1] = "HOME=/";
        envp[2] = "TERM=linux";
        envp[3] = "USER=root";
        envp[4] = "LOGNAME=root";
        envp[5] = "SHELL=/bin/sh";
        envp[6] = "LANG=C.UTF-8";
        envp[7] = "PS1=\\u@lexos:\\w\\$ ";
        envp[8] = tz;
        envp[9] = pwd;
        envp[10] = 0;
    }
    lx_op(LXO_MAP, 0, 0);                                 /* (its own page directory) */
    h = lx_op(LXO_ELF, 0, 0);
    if (h < 0) { puts("LINUX.APP: which program? (run busybox ls)\n"); return 1; }
    {                                                     /* where it is (for /proc/self/exe) */
        static char c0[256];
        lx_op(LXO_ELFPATH, (int)c0, 0);
        to_utf(exe_name, c0, sizeof exe_name);
        scopy(procs[0].exe, c0, sizeof procs[0].exe);
        if (same_ci(base_name(c0), "busybox")) note_busybox(c0, h);
    }
    {
        struct lxstat st;
        if (!busybox_known) {                             /* BusyBox in /LINUX or /BIN? */
            static const char *where[] = { "/LINUX/BUSYBOX", "/DOWNLOADS/BUSYBOX", "/BIN/BUSYBOX", 0 };
            for (i = 0; where[i]; i++)
                if (!vstat(where[i], &st)) { int h2 = open(where[i], O_READ); if (h2 >= 0) { note_busybox(where[i], h2); close(h2); } break; }
        }
    }
    {
        struct lxstat st;
        trace = !vstat("/TMP/LXTRACE", &st);
    }
    r = load_elf(h);
    close(h);
    if (r) {
        char t[200];
        char *q = stpcopy(t, "LINUX.APP: can't run it: ");
        q = stpcopy(q, load_err);
        q = stpcopy(q, "\n");
        write(t, q - t);
        return 126;
    }
    memset(&F, 0, sizeof F);
    F.esp = build_stack(largv, envp);
    F.eip = auxv_entry;
    F.eflags = 0x202;
    reg.handler = (unsigned)lx_entry;
    reg.stack = ((unsigned)hstack + sizeof hstack) & ~15u;
    reg.frame = (unsigned)&F;
    lx_op(LXO_REGISTER, (int)&reg, 0);
    resume();
    return 0;
}
