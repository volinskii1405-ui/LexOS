/* music.c - LexOS Music: a player for WAV, MOD and IMF, with a playlist.
 *
 *   run music.app [file]      (Files opens .WAV .MOD .IMF in it)
 *
 * Opened with a file, the list is every piece of music in its folder,
 * and that one plays; without, it's /DEMOS's. "Add..." puts more in,
 * from anywhere; Delete takes the chosen one out.
 *
 * WAV (8 or 16 bits, mono or stereo, any rate) and MOD (ProTracker,
 * mod.h) play through the Sound Blaster; IMF (id Software's AdLib
 * music) through the AdLib chip, a register at a time (opl()).
 *
 *   Space play / pause      Enter play the chosen one   S stop
 *   Left / Right  5 s back / on (or a click on the bar)
 *   N / P  the next / the one before    Up / Down  choose
 *   + / -  louder / quieter  R repeat (off, all, one)   H shuffle
 *   Esc quits */
#include "gui.h"
#include "mod.h"

#define W 560
#define H 460
#define TOP_H 176
#define LIST_Y (TOP_H + 8)
#define ROW_H 20
#define LIST_ROWS ((H - LIST_Y - 44) / ROW_H)
#define MAXT 64

#define C_TOP    RGB(28, 34, 52)
#define C_TOP2   RGB(44, 54, 82)
#define C_ACC    RGB(90, 170, 255)
#define C_WHITE  RGB(255, 255, 255)
#define C_DIM    RGB(150, 160, 185)
#define C_BG     RGB(246, 247, 250)
#define C_TEXT   RGB(28, 30, 36)
#define C_GRAY   RGB(120, 126, 138)
#define C_SEL    RGB(214, 228, 250)
#define C_PLAY   RGB(40, 90, 200)

#define T_WAV 1
#define T_MOD 2
#define T_IMF 3

struct track { char path[128]; char name[16]; int type; unsigned ms; };
static struct track list[MAXT];
static int ntracks, sel = -1, cur = -1, top;
static int state;                               /* 0 stopped, 1 playing, 2 paused */
static int volume = 80, repeat, shuffle, hover = -1, drag_vol, sound_ok = 1;
static char status[80];
static unsigned seed;

/* ---- the one playing ---- */
static int fd = -1, w_rate, w_ch, w_bits, w_off, w_len, w_read;
static unsigned char *buf;                      /* a MOD's or an IMF's bytes */
static int buf_size;
static unsigned char *imf;                      /* IMF records */
static int imf_n, imf_i;
static unsigned imf_at, imf_t0, pause_ms;       /* IMF: ticks at 560Hz */
static unsigned played_frames;                  /* WAV / MOD: frames given to the card */
static int voice_open, voice_rate, voice_ch;

static unsigned le16(const unsigned char *p) { return p[0] | p[1] << 8; }
static unsigned le32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (unsigned)p[3] << 24; }
static void time_text(unsigned ms, char *o)
{
    unsigned s = ms / 1000;
    char n[12];
    gui_num(o, s / 60);
    gui_cat(o, ":");
    if (s % 60 < 10) gui_cat(o, "0");
    gui_cat(o, gui_num(n, s % 60));
}
static int type_of(const char *name)
{
    if (gui_ext_ok(name, "WAV")) return T_WAV;
    if (gui_ext_ok(name, "MOD")) return T_MOD;
    if (gui_ext_ok(name, "IMF")) return T_IMF;
    return 0;
}

/* ============================================================
 * files: a WAV's header, the whole of a MOD / IMF
 * ============================================================ */
/* fd at a WAV -> its format (w_*), 1 if it's one this can play */
static int wav_header(int f)
{
    unsigned char h[12], c[8], fmt[16];
    int at = 12;
    w_len = 0;
    seek(f, 0);
    if (read(f, h, 12) != 12 || memcmp(h, "RIFF", 4) || memcmp(h + 8, "WAVE", 4)) return 0;
    w_rate = 0;
    for (;;) {
        unsigned n;
        seek(f, at);
        if (read(f, c, 8) != 8) return 0;
        n = le32(c + 4);
        if (!memcmp(c, "fmt ", 4)) {
            if (read(f, fmt, 16) != 16) return 0;
            if (le16(fmt) != 1) return 0;                   /* PCM only */
            w_ch = le16(fmt + 2); w_rate = le32(fmt + 4); w_bits = le16(fmt + 14);
        } else if (!memcmp(c, "data", 4)) {
            w_off = at + 8; w_len = n;
            break;
        }
        at += 8 + n + (n & 1);
    }
    if (!w_rate || (w_ch != 1 && w_ch != 2) || (w_bits != 8 && w_bits != 16)) return 0;
    if (w_len > fsize(f) - w_off) w_len = fsize(f) - w_off;
    return 1;
}
static unsigned char *load_all(const char *p, int *n)
{
    int f = open(p, O_READ);
    unsigned char *b;
    if (f < 0) return 0;
    *n = fsize(f);
    b = malloc(*n + 4);
    if (b) *n = read(f, b, *n);
    close(f);
    return b;
}
/* an IMF's records: type 0 (none before), or 1 (their length first) */
static void imf_setup(unsigned char *b, int n)
{
    unsigned l = le16(b);
    imf = b; imf_n = n / 4;
    if (l && l + 2 <= (unsigned)n && l % 4 == 0 && n > 2) { imf = b + 2; imf_n = l / 4; }
}
static unsigned imf_ticks(void) { unsigned t = 0; int i; for (i = 0; i < imf_n; i++) t += le16(imf + i * 4 + 2); return t; }

/* a track's length, found out as it's added */
static void measure(struct track *t)
{
    t->ms = 0;
    if (t->type == T_WAV) {
        int f = open(t->path, O_READ);
        if (f >= 0) { if (wav_header(f)) t->ms = (unsigned)((double)w_len * 1000 / (w_rate * w_ch * (w_bits / 8))); close(f); }
    } else {
        int n;
        unsigned char *b = load_all(t->path, &n);
        if (!b) return;
        if (t->type == T_MOD) { if (mod_open(b, n)) t->ms = (unsigned)((double)mod_length() * 1000 / RATE); }
        else { imf_setup(b, n); t->ms = imf_ticks() * 1000 / 560; }
        free(b);
    }
}
static void add(const char *path)
{
    struct track *t;
    const char *b = path, *p;
    int i;
    if (ntracks >= MAXT) { strcpy(status, "The list is full."); return; }
    for (p = path; *p; p++) if (*p == '/') b = p + 1;
    if (!type_of(b)) return;
    for (i = 0; i < ntracks; i++) if (!strcmp(list[i].path, path)) return;
    t = &list[ntracks];
    strcpy(t->path, path);
    for (i = 0; b[i] && i < 15; i++) t->name[i] = b[i];
    t->name[i] = 0;
    t->type = type_of(b);
    measure(t);
    ntracks++;
}
static void add_folder(const char *dir)
{
    struct lx_dirent e;
    char p[128];
    int i;
    for (i = 0; readdir(dir, i, &e) == 0; i++) {
        if (e.type == LX_DIR || !type_of(e.name) || strlen(dir) + strlen(e.name) > 120) continue;
        strcpy(p, dir);
        if (strcmp(dir, "/")) gui_cat(p, "/");
        gui_cat(p, e.name);
        add(p);
    }
}

/* ============================================================
 * playing
 * ============================================================ */
static void opl_quiet(void)
{
    int i;
    for (i = 0; i < 9; i++) opl(0xB0 + i, 0);           /* every note off */
}
static void stop_all(void)
{
    if (voice_open) audio_queued(1);
    if (fd >= 0) { close(fd); fd = -1; }
    if (cur >= 0 && list[cur].type == T_IMF && state) opl_quiet();
    free(buf); buf = 0; imf = 0;
    state = 0;
}
static int voice(int rate, int ch)
{
    if (voice_open && voice_rate == rate && voice_ch == ch) { audio_queued(1); return 1; }
    if (voice_open) { audio_queued(1); audio_close(); voice_open = 0; }
    if (audio_open(rate, ch) < 0) { strcpy(status, "No sound card (QEMU: -device sb16)."); sound_ok = 0; return 0; }
    voice_open = 1; voice_rate = rate; voice_ch = ch;
    audio_volume(volume);
    sound_ok = 1;
    return 1;
}
/* where the one playing is, in ms */
static unsigned position(void)
{
    struct track *t;
    int q;
    if (cur < 0 || !state) return 0;
    t = &list[cur];
    if (t->type == T_IMF) return state == 2 ? pause_ms : (millis() - imf_t0);
    q = voice_open ? audio_queued(0) : 0;
    if (q < 0) q = 0;
    if (t->type == T_WAV) {
        unsigned frames = played_frames > (unsigned)(q / (2 * w_ch)) ? played_frames - q / (2 * w_ch) : 0;
        return (unsigned)((double)frames * 1000 / w_rate);
    }
    return (unsigned)((double)(played_frames > (unsigned)q / 4 ? played_frames - q / 4 : 0) * 1000 / RATE);
}
/* IMF from ms on: the registers up to there written at once */
static void imf_from(unsigned ms)
{
    unsigned target = ms * 56 / 100;
    opl_quiet();
    imf_i = 0; imf_at = 0;
    while (imf_i < imf_n && imf_at + le16(imf + imf_i * 4 + 2) <= target) {
        const unsigned char *r = imf + imf_i * 4;
        if (r[0]) opl(r[0], r[1]);
        imf_at += le16(r + 2);
        imf_i++;
    }
    opl_quiet();                                          /* (no stuck notes) */
    imf_t0 = millis() - imf_at * 100 / 56;
}
static void seek_to(unsigned ms)
{
    struct track *t;
    if (cur < 0 || !state) return;
    t = &list[cur];
    if (ms > t->ms) ms = t->ms;
    if (t->type == T_IMF) { imf_from(ms); if (state == 2) pause_ms = ms; return; }
    if (voice_open) audio_queued(1);
    if (t->type == T_WAV) {
        int bpf = w_ch * (w_bits / 8);
        unsigned fr = (unsigned)((double)ms * w_rate / 1000);
        w_read = fr * bpf;
        if (w_read > w_len) w_read = w_len;
        seek(fd, w_off + w_read);
        played_frames = fr;
    } else {
        mod_seek((unsigned)((double)ms * RATE / 1000));
        played_frames = mod_frames;
    }
}
static void play(int i)
{
    struct track *t;
    stop_all();
    if (i < 0 || i >= ntracks) return;
    cur = i; sel = i;
    t = &list[i];
    status[0] = 0;
    played_frames = 0;
    if (t->type == T_WAV) {
        fd = open(t->path, O_READ);
        if (fd < 0 || !wav_header(fd)) { strcpy(status, "Can't play that WAV."); if (fd >= 0) close(fd); fd = -1; return; }
        if (!voice(w_rate, w_ch)) return;
        seek(fd, w_off);
        w_read = 0;
    } else {
        buf = load_all(t->path, &buf_size);
        if (!buf) { strcpy(status, "Can't open it."); return; }
        if (t->type == T_MOD) {
            if (!mod_open(buf, buf_size)) { strcpy(status, "Not a 4-channel MOD."); free(buf); buf = 0; return; }
            if (!voice(RATE, 2)) return;
        } else {
            imf_setup(buf, buf_size);
            if (voice_open) { audio_queued(1); audio_close(); voice_open = 0; }
            opl(1, 0x20);                                  /* waveforms on */
            imf_from(0);
        }
    }
    state = 1;
}
static int pick_next(int dir)
{
    if (!ntracks) return -1;
    if (shuffle && ntracks > 1) {
        int n;
        seed = seed * 1103515245 + 12345;
        n = (seed >> 16) % (ntracks - 1);
        return n >= cur ? n + 1 : n;
    }
    if (cur + dir >= ntracks) return repeat ? 0 : -1;
    if (cur + dir < 0) return ntracks - 1;
    return cur + dir;
}
static void finished(void)
{
    int n;
    if (repeat == 2) { play(cur); return; }
    n = pick_next(1);
    if (n < 0) { stop_all(); return; }
    play(n);
}
static void pause_toggle(void)
{
    if (!state) { play(sel >= 0 ? sel : 0); return; }
    if (state == 1) {
        pause_ms = position();
        if (list[cur].type == T_IMF) opl_quiet();
        else {                                             /* what's queued: dropped, */
            int q = audio_queued(0), bpf = list[cur].type == T_WAV ? 2 * w_ch : 4;
            if (q > 0) {                                  /* and given back */
                if (list[cur].type == T_WAV) { w_read -= q / bpf * w_ch * (w_bits / 8); if (w_read < 0) w_read = 0; seek(fd, w_off + w_read); played_frames -= q / bpf; }
                else { mod_seek(pause_ms * (RATE / 1000)); played_frames = mod_frames; }
            }
            audio_queued(1);
        }
        state = 2;
    } else {
        state = 1;
        if (list[cur].type == T_IMF) imf_from(pause_ms);
    }
}
/* the card kept fed (a quarter of a second ahead), the AdLib on time */
static void feed(void)
{
    static short tmp[4096];
    struct track *t;
    if (cur < 0 || state != 1) return;
    t = &list[cur];
    if (t->type == T_IMF) {
        unsigned now = (millis() - imf_t0) * 56 / 100;
        while (imf_i < imf_n && imf_at <= now) {
            const unsigned char *r = imf + imf_i * 4;
            if (r[0]) opl(r[0], r[1]);
            imf_at += le16(r + 2);
            imf_i++;
        }
        if (imf_i >= imf_n) { opl_quiet(); finished(); }
        return;
    }
    if (t->type == T_WAV) {
        int ahead = w_rate * w_ch * 2 / 4;
        while (audio_queued(0) < ahead) {
            int bps = w_bits / 8, n = sizeof tmp / 2 * bps / (bps == 1 ? 2 : 1), got, i;
            if (n > w_len - w_read) n = w_len - w_read;
            n -= n % (w_ch * bps);
            if (n <= 0) { if (audio_queued(0) <= 0) finished(); return; }
            if (bps == 2) got = read(fd, tmp, n);
            else {
                unsigned char *b8 = (unsigned char *)tmp + sizeof tmp / 2;
                got = read(fd, b8, n);
                for (i = 0; i < got; i++) tmp[i] = (b8[i] - 128) << 8;
                got *= 2;
            }
            if (got <= 0) { if (audio_queued(0) <= 0) finished(); return; }
            w_read += bps == 2 ? got : got / 2;
            audio_write(tmp, got);
            played_frames += got / (2 * w_ch);
        }
        return;
    }
    while (audio_queued(0) < RATE) {                     /* MOD: a quarter second (in bytes) */
        int n = mod_tick(0);
        if (!n) { if (audio_queued(0) <= 0) finished(); return; }
        audio_write(out, n * 4);
        played_frames += n;
    }
}

/* ============================================================
 * drawing
 * ============================================================ */
#define BTN_Y 132
#define BAR_Y 100
static const char *btn_label[] = { "|<", ">", "[]", ">|" };
static int bx(int i) { return 20 + i * 52; }
#define VOL_X 260
#define VOL_W 120
#define TOG_X 400

static void draw(void)
{
    int i, pos_ms = position();
    char t[64], n[16];
    struct track *tr = cur >= 0 ? &list[cur] : 0;
    for (i = 0; i < TOP_H; i++) gui_fill(0, i, W, 1, gui_mix(C_TOP2, C_TOP, i * 256 / TOP_H));
    /* a record, turning while it plays */
    {
        int cx = W - 58, cy = 50, r;
        for (r = 38; r > 0; r -= 3) gui_disc(cx, cy, r, r > 13 ? (r % 6 == 2 ? RGB(18, 20, 28) : RGB(40, 42, 54)) : r > 4 ? C_ACC : RGB(18, 20, 28));
        {                                                   /* a shine that turns */
            static const int dx[8] = { 0, 18, 26, 18, 0, -18, -26, -18 }, dy[8] = { -26, -18, 0, 18, 26, 18, 0, -18 };
            unsigned a = state == 1 ? millis() / 90 % 8 : 1;
            gui_disc(cx + dx[a], cy + dy[a], 3, RGB(120, 130, 160));
        }
    }
    if (tr) {
        {
            static const char *kind[4] = { "", "WAV", "MOD", "IMF (AdLib)" };
            strcpy(t, kind[tr->type]);
            if (tr->type == T_WAV && state) { gui_cat(t, " "); gui_cat(t, gui_num(n, w_rate)); gui_cat(t, " Hz "); gui_cat(t, w_ch == 2 ? "stereo" : "mono"); }
            gui_text(20, 54, t, C_DIM, 1);
        }
        gui_text(20, 18, tr->name, C_WHITE, 2);
    } else gui_text(20, 18, "LexOS Music", C_WHITE, 2);
    if (status[0]) gui_text(20, 74, status, RGB(255, 170, 120), 1);
    /* the bar: where it is */
    time_text(pos_ms, t);
    gui_text(20, BAR_Y + 12, t, C_DIM, 1);
    time_text(tr ? tr->ms : 0, t);
    gui_text(W - 20 - gui_text_w(t, 1), BAR_Y + 12, t, C_DIM, 1);
    gui_round(20, BAR_Y, W - 40, 8, 3, RGB(60, 70, 100));
    if (tr && tr->ms) {
        int w = (int)((double)(W - 40) * (pos_ms > (int)tr->ms ? (int)tr->ms : pos_ms) / tr->ms);
        if (w > 4) gui_round(20, BAR_Y, w, 8, 3, C_ACC);
        gui_round(20 + w - 6, BAR_Y - 4, 16, 16, 7, C_WHITE);
    }
    /* the buttons */
    for (i = 0; i < 4; i++) {
        const char *l = btn_label[i];
        gui_round(bx(i), BTN_Y, 44, 36, 8, hover == i ? RGB(90, 110, 160) : RGB(60, 72, 108));
        if (i == 1) {                                       /* play, or pause */
            if (state == 1) { gui_fill(bx(i) + 15, BTN_Y + 10, 5, 16, C_WHITE); gui_fill(bx(i) + 24, BTN_Y + 10, 5, 16, C_WHITE); }
            else { int k; for (k = 0; k < 16; k++) gui_fill(bx(i) + 16, BTN_Y + 10 + k, k < 8 ? k + 1 : 16 - k, 1, C_WHITE); }
        } else if (i == 2) gui_fill(bx(i) + 15, BTN_Y + 11, 14, 14, C_WHITE);
        else gui_text_c(bx(i) + 22, BTN_Y + 10, l, C_WHITE, 1);
    }
    /* the volume */
    gui_text(VOL_X, BTN_Y - 2, "Volume", C_DIM, 1);
    gui_round(VOL_X, BTN_Y + 22, VOL_W, 6, 2, RGB(60, 70, 100));
    gui_round(VOL_X, BTN_Y + 22, VOL_W * volume / 100, 6, 2, C_ACC);
    gui_round(VOL_X + VOL_W * volume / 100 - 6, BTN_Y + 17, 14, 14, 6, C_WHITE);
    /* repeat, shuffle */
    strcpy(t, repeat == 0 ? "Repeat: off" : repeat == 1 ? "Repeat: all" : "Repeat: one");
    gui_round(TOG_X, BTN_Y, 140, 16, 3, hover == 10 ? RGB(90, 110, 160) : RGB(60, 72, 108));
    gui_text_c(TOG_X + 70, BTN_Y, t, repeat ? C_WHITE : C_DIM, 1);
    gui_round(TOG_X, BTN_Y + 20, 140, 16, 3, hover == 11 ? RGB(90, 110, 160) : RGB(60, 72, 108));
    gui_text_c(TOG_X + 70, BTN_Y + 20, shuffle ? "Shuffle: on" : "Shuffle: off", shuffle ? C_WHITE : C_DIM, 1);
    /* the list */
    gui_fill(0, TOP_H, W, H - TOP_H, C_BG);
    for (i = 0; i < LIST_ROWS && top + i < ntracks; i++) {
        struct track *x = &list[top + i];
        int y = LIST_Y + i * ROW_H, k = top + i;
        static const char *kind[4] = { "", "WAV", "MOD", "IMF" };
        if (k == sel) gui_fill(8, y, W - 16, ROW_H, C_SEL);
        gui_num(n, k + 1);
        gui_text(40 - gui_text_w(n, 1), y + 2, n, C_GRAY, 1);
        if (k == cur && state) {                            /* a speaker by the one playing */
            gui_fill(50, y + 7, 3, 6, C_PLAY); gui_fill(53, y + 5, 3, 10, C_PLAY);
        }
        gui_text(64, y + 2, x->name, k == cur ? C_PLAY : C_TEXT, 1);
        gui_text(W - 150, y + 2, kind[x->type], C_GRAY, 1);
        time_text(x->ms, t);
        gui_text(W - 20 - gui_text_w(t, 1), y + 2, t, C_GRAY, 1);
    }
    if (!ntracks) gui_text_c(W / 2, LIST_Y + 40, "No music here: Add... puts some in.", C_GRAY, 1);
    gui_button(8, H - 36, 90, 28, "Add...", hover == 20);
    gui_button(106, H - 36, 90, 28, "Remove", hover == 21);
    gui_button(204, H - 36, 90, 28, "Clear", hover == 22);
    gui_num(n, ntracks);
    strcpy(t, n); gui_cat(t, ntracks == 1 ? " piece" : " pieces");
    gui_text(W - 12 - gui_text_w(t, 1), H - 30, t, C_GRAY, 1);
    gui_show();
}

static int hit(int mx, int my)
{
    int i;
    for (i = 0; i < 4; i++) if (gui_in(mx, my, bx(i), BTN_Y, 44, 36)) return i;
    if (gui_in(mx, my, TOG_X, BTN_Y, 140, 16)) return 10;
    if (gui_in(mx, my, TOG_X, BTN_Y + 18, 140, 18)) return 11;
    if (gui_in(mx, my, 8, H - 36, 90, 28)) return 20;
    if (gui_in(mx, my, 106, H - 36, 90, 28)) return 21;
    if (gui_in(mx, my, 204, H - 36, 90, 28)) return 22;
    if (gui_in(mx, my, VOL_X - 8, BTN_Y + 12, VOL_W + 16, 24)) return 30;
    if (gui_in(mx, my, 12, BAR_Y - 6, W - 24, 20)) return 31;
    return -1;
}
static void set_volume(int v)
{
    volume = v < 0 ? 0 : v > 100 ? 100 : v;
    if (voice_open) audio_volume(volume);
}
static void remove_sel(void)
{
    if (sel < 0 || sel >= ntracks) return;
    if (sel == cur) { stop_all(); cur = -1; }
    memmove(&list[sel], &list[sel + 1], (ntracks - sel - 1) * sizeof list[0]);
    ntracks--;
    if (cur > sel) cur--;
    if (sel >= ntracks) sel = ntracks - 1;
}
static void press(int b, int mx)
{
    char p[128];
    switch (b) {
    case 0: if (cur >= 0 && position() > 3000) seek_to(0); else if (ntracks) play(pick_next(-1)); break;
    case 1: pause_toggle(); break;
    case 2: stop_all(); break;
    case 3: if (ntracks) { int n = pick_next(1); if (n < 0) n = 0; play(n); } break;
    case 10: repeat = (repeat + 1) % 3; break;
    case 11: shuffle = !shuffle; break;
    case 20:
        strcpy(p, cur >= 0 ? list[cur].path : "/DEMOS");
        if (gui_file_dialog("Add music", p, 0, "WAV MOD IMF")) { add(p); sel = ntracks - 1; }
        break;
    case 21: remove_sel(); break;
    case 22: stop_all(); ntracks = 0; cur = sel = -1; break;
    case 31: if (cur >= 0 && list[cur].ms) seek_to((unsigned)((double)(mx - 20) * list[cur].ms / (W - 40))); break;
    }
}

int main(int argc, char **argv)
{
    int m[4], was = 0, i;
    unsigned last_click = 0, last_draw = 0;
    if (gui_open(W, H) < 0) { puts("music: needs a 560x460 window in 32 bits\n"); return 1; }
    seed = millis();
    volume = gui_cfg_get("musicvol", 80);
    if (argc > 1) {
        char p[128], dir[128];
        int cut = 0;
        for (i = 0; argv[1][i] && i < 126; i++) p[i] = gui_upper(argv[1][i]);
        p[i] = 0;
        if (p[0] != '/') { dir[0] = '/'; strcpy(dir + 1, p); strcpy(p, dir); }
        for (i = 0; p[i]; i++) if (p[i] == '/') cut = i;
        memcpy(dir, p, cut); dir[cut ? cut : 1] = 0;
        add_folder(dir);
        add(p);
        for (i = 0; i < ntracks; i++) if (!strcmp(list[i].path, p)) play(i);
    } else add_folder("/DEMOS");
    draw();
    for (;;) {
        int k, changed = 0;
        char in[128];
        while ((k = pollkey())) {
            int ch = k & 0xFF, sc = (k >> 8) & 0xFF;
            changed = 1;
            if (sc == KEY_ESC) { stop_all(); if (voice_open) audio_close(); gui_cfg_set("musicvol", volume); return 0; }
            if (ch == ' ') pause_toggle();
            else if (ch == 13) { if (sel >= 0) play(sel); }
            else if (ch == 's' || ch == 'S') stop_all();
            else if (ch == 'n' || ch == 'N') press(3, 0);
            else if (ch == 'p' || ch == 'P') press(0, 0);
            else if (ch == 'r' || ch == 'R') press(10, 0);
            else if (ch == 'h' || ch == 'H') press(11, 0);
            else if (ch == '+' || ch == '=') set_volume(volume + 10);
            else if (ch == '-') set_volume(volume - 10);
            else if (sc == KEY_RIGHT && !ch) seek_to(position() + 5000);
            else if (sc == KEY_LEFT && !ch) { unsigned p = position(); seek_to(p > 5000 ? p - 5000 : 0); }
            else if (sc == KEY_UP && !ch) { if (sel > 0) sel--; }
            else if (sc == KEY_DOWN && !ch) { if (sel < ntracks - 1) sel++; }
            else if (sc == 0x53) remove_sel();
            if (sel >= 0 && sel < top) top = sel;
            if (sel >= top + LIST_ROWS) top = sel - LIST_ROWS + 1;
        }
        if (inbox(in, sizeof in) > 0) {                   /* a file from Files: in, and on */
            add(in);
            for (i = 0; i < ntracks; i++) if (!strcmp(list[i].path, in)) play(i);
            changed = 1;
        }
        if (mouse(m)) {
            int mx = m[0], my = m[1], down = m[2] & 1, h = hit(mx, my);
            if (h != hover) { hover = h; changed = 1; }
            if (m[3] && my > TOP_H) { top += m[3] * 3; if (top > ntracks - LIST_ROWS) top = ntracks - LIST_ROWS; if (top < 0) top = 0; changed = 1; }
            if (down && !was) {
                unsigned now = millis();
                changed = 1;
                if (h == 30) drag_vol = 1;
                else if (h >= 0) press(h, mx);
                else if (my >= LIST_Y && my < LIST_Y + LIST_ROWS * ROW_H) {
                    int r = top + (my - LIST_Y) / ROW_H;
                    if (r < ntracks) {
                        if (r == sel && now - last_click < 400) play(r);
                        sel = r;
                    }
                }
                last_click = now;
            }
            if (down && drag_vol) { set_volume((mx - VOL_X) * 100 / VOL_W); changed = 1; }
            if (!down) drag_vol = 0;
            was = down;
        } else if (hover >= 0) { hover = -1; changed = 1; }
        feed();
        if (state == 1 && millis() - last_draw > 250) changed = 1;   /* the time moves on */
        if (changed) { draw(); last_draw = millis(); }
        sleep_ms(10);
    }
    return 0;
}
