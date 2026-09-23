/* modplay.c - plays ProTracker .MOD music: run modplay.app SONG.MOD
 * Four channels mixed in software into 16-bit stereo at 22050Hz and
 * streamed to the Sound Blaster with audio_write(). Esc stops.
 * The usual effects: arpeggio, portamento (up/down/to note), vibrato,
 * volume slides, sample offset, jumps and breaks, speed and tempo,
 * and the fine slides / note cut of the E commands.
 * Integer math only. */
#include "lexos.h"

#define RATE     22050
#define CHANNELS 4
#define PAL_CLOCK 3546895u

struct sample {
    char name[23];
    signed char *data;
    unsigned len, loop_start, loop_len;               /* in bytes */
    int volume;
};

struct channel {
    struct sample *smp;
    unsigned pos, frac, step;                           /* pos.frac: 16-bit fraction */
    int period, base_period, target, volume;
    int effect, param, porta_speed;
    int vib_pos, vib_speed, vib_depth;
    int active;
};

static unsigned char *mod;
static int mod_size, song_len, patterns;
static unsigned char *order;
static struct sample samples[32];
static struct channel ch[CHANNELS];
static int speed = 6, bpm = 125, tick, row, pos, next_row = -1, next_pos = -1;
static unsigned step_k;                                 /* (PAL_CLOCK << 8) / RATE */
static short out[RATE / 10 * 2 + 8];                    /* one tick at the slowest tempo */

static const short periods[36] = {
    856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
    428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
    214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113
};
static const unsigned char sine[32] = {
    0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
    255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24
};

static unsigned be16(const unsigned char *p) { return p[0] << 8 | p[1]; }

static void set_step(struct channel *c, int period)
{
    if (period < 28) period = 28;
    c->step = (step_k << 8) / (unsigned)period;
}

static int note_index(int period)
{
    int i;
    for (i = 0; i < 36; i++) if (period >= periods[i]) return i;
    return 35;
}

static int load(const char *name)
{
    int fd = open(name, O_READ), i, off;
    if (fd < 0) { puts("Can't open "); puts(name); putchar('\n'); return 0; }
    mod_size = fsize(fd);
    mod = malloc(mod_size + 1);
    if (!mod) { puts("Too big for memory.\n"); close(fd); return 0; }
    read(fd, mod, mod_size);
    close(fd);
    if (mod_size < 1084 || (memcmp(mod + 1080, "M.K.", 4) && memcmp(mod + 1080, "4CHN", 4)
        && memcmp(mod + 1080, "FLT4", 4) && memcmp(mod + 1080, "M!K!", 4))) {
        puts("Not a 4-channel ProTracker module.\n");
        return 0;
    }
    song_len = mod[950];
    if (song_len < 1 || song_len > 128) song_len = 1;
    order = mod + 952;
    patterns = 0;
    for (i = 0; i < 128; i++) if (order[i] + 1 > patterns) patterns = order[i] + 1;
    off = 1084 + patterns * 1024;
    for (i = 1; i <= 31; i++) {
        const unsigned char *h = mod + 20 + (i - 1) * 30;
        struct sample *s = &samples[i];
        memcpy(s->name, h, 22);
        s->name[22] = 0;
        s->len = be16(h + 22) * 2;
        s->volume = h[25] > 64 ? 64 : h[25];
        s->loop_start = be16(h + 26) * 2;
        s->loop_len = be16(h + 28) * 2;
        if (off + (int)s->len > mod_size) s->len = off < mod_size ? mod_size - off : 0;
        s->data = (signed char *)mod + off;
        off += be16(h + 22) * 2;
        if (s->loop_len <= 2 || s->loop_start >= s->len) s->loop_len = 0;
        else if (s->loop_start + s->loop_len > s->len) s->loop_len = s->len - s->loop_start;
    }
    return 1;
}

static void slide_volume(struct channel *c, int param)
{
    if (param >> 4) c->volume += param >> 4; else c->volume -= param & 15;
    if (c->volume < 0) c->volume = 0;
    if (c->volume > 64) c->volume = 64;
}

static void tone_porta(struct channel *c)
{
    if (!c->target) return;
    if (c->period < c->target) { c->period += c->porta_speed; if (c->period > c->target) c->period = c->target; }
    else if (c->period > c->target) { c->period -= c->porta_speed; if (c->period < c->target) c->period = c->target; }
    c->base_period = c->period;
    set_step(c, c->period);
}

static void vibrato(struct channel *c)
{
    int delta = sine[c->vib_pos & 31] * c->vib_depth / 128;
    if (c->vib_pos & 32) delta = -delta;
    set_step(c, c->period + delta);
    c->vib_pos += c->vib_speed;
}

/* the start of a row: new notes, and the effects that act on tick 0 */
static void play_row(void)
{
    const unsigned char *p = mod + 1084 + order[pos] * 1024 + row * 16;
    int i;
    for (i = 0; i < CHANNELS; i++, p += 4) {
        struct channel *c = &ch[i];
        int smp = (p[0] & 0xF0) | p[2] >> 4, period = (p[0] & 15) << 8 | p[1];
        int fx = p[2] & 15, param = p[3];
        c->effect = fx;
        c->param = param;
        if (smp && smp <= 31) { c->smp = &samples[smp]; c->volume = c->smp->volume; }
        if (period) {
            if (fx == 3 || fx == 5) c->target = period;
            else {
                c->period = c->base_period = period;
                c->pos = c->frac = 0;
                c->vib_pos = 0;
                c->active = c->smp != 0;
                set_step(c, period);
            }
        }
        switch (fx) {
        case 3: if (param) c->porta_speed = param; break;
        case 4:
            if (param >> 4) c->vib_speed = param >> 4;
            if (param & 15) c->vib_depth = param & 15;
            break;
        case 9: if (period) c->pos = param * 256; break;
        case 11: next_pos = param; break;
        case 12: c->volume = param > 64 ? 64 : param; break;
        case 13:
            next_row = (param >> 4) * 10 + (param & 15);
            if (next_pos < 0) next_pos = pos + 1;
            break;
        case 14:
            switch (param >> 4) {
            case 1: c->period -= param & 15; if (c->period < 113) c->period = 113; set_step(c, c->period); break;
            case 2: c->period += param & 15; if (c->period > 856) c->period = 856; set_step(c, c->period); break;
            case 10: slide_volume(c, (param & 15) << 4); break;
            case 11: slide_volume(c, param & 15); break;
            }
            break;
        case 15:
            if (param == 0) break;
            if (param < 32) speed = param; else bpm = param;
            break;
        }
    }
}

/* ticks 1..speed-1: the continuous effects */
static void play_tick(void)
{
    int i;
    for (i = 0; i < CHANNELS; i++) {
        struct channel *c = &ch[i];
        int param = c->param;
        switch (c->effect) {
        case 0:
            if (param) {
                int n = note_index(c->base_period), add = tick % 3 == 1 ? param >> 4 : tick % 3 == 2 ? param & 15 : 0;
                set_step(c, periods[n + add > 35 ? 35 : n + add]);
            }
            break;
        case 1: c->period -= param; if (c->period < 113) c->period = 113; set_step(c, c->period); break;
        case 2: c->period += param; if (c->period > 856) c->period = 856; set_step(c, c->period); break;
        case 3: tone_porta(c); break;
        case 4: vibrato(c); break;
        case 5: tone_porta(c); slide_volume(c, param); break;
        case 6: vibrato(c); slide_volume(c, param); break;
        case 10: slide_volume(c, param); break;
        case 14: if ((param >> 4) == 12 && tick == (param & 15)) c->volume = 0; break;
        }
    }
}

/* n frames of the four channels -> out[] (left, right) */
static void mix(int n)
{
    int f, i;
    for (f = 0; f < n; f++) {
        int left = 0, right = 0;
        for (i = 0; i < CHANNELS; i++) {
            struct channel *c = &ch[i];
            struct sample *s = c->smp;
            int v;
            if (!c->active || !s || !s->len) continue;
            v = s->data[c->pos] * c->volume;
            if (i == 0 || i == 3) { left += v * 3; right += v; }   /* Amiga: L R R L, */
            else { right += v * 3; left += v; }                  /* softened a little */
            c->frac += c->step;
            c->pos += c->frac >> 16;
            c->frac &= 0xFFFF;
            if (c->pos >= s->len || (s->loop_len && c->pos >= s->loop_start + s->loop_len)) {
                if (s->loop_len) c->pos = s->loop_start + (c->pos - s->loop_start) % s->loop_len;
                else c->active = 0;
            }
        }
        left >>= 3; right >>= 3;
        out[f * 2] = left > 32767 ? 32767 : left < -32768 ? -32768 : left;
        out[f * 2 + 1] = right > 32767 ? 32767 : right < -32768 ? -32768 : right;
    }
}

static void show_position(void)
{
    setcursor(22, 0);
    setcolor(0x0E);
    puts("Position ");
    print_int(pos + 1); puts("/"); print_int(song_len);
    puts("  row "); print_int(row); puts("   tempo "); print_int(bpm);
    puts("  speed "); print_int(speed); puts("    ");
    setcolor(0x07);
}

int main(int argc, char **argv)
{
    int i, rows_played = 0;
    if (argc < 2) { puts("Usage: run modplay.app SONG.MOD   (Esc stops)\n"); return 1; }
    if (!load(argv[1])) return 1;
    if (audio_open(RATE, 2) < 0) { puts("No sound card (QEMU: -device sb16).\n"); return 1; }
    step_k = (PAL_CLOCK << 8) / RATE;

    clear();
    setcolor(0x0B);
    puts("LexOS MOD player - ");
    write((const char *)mod, strlen((const char *)mod) > 20 ? 20 : strlen((const char *)mod));
    puts("\n\n");
    setcolor(0x07);
    for (i = 1; i <= 31; i++)
        if (samples[i].name[0] && i <= 40) {
            setcursor(2 + (i - 1) % 18, (i - 1) / 18 * 40);
            print_int(i); puts(". "); puts(samples[i].name);
        }
    setcursor(21, 0);
    puts("Esc stops.");

    pos = row = 0;
    while (pos < song_len) {
        play_row();
        if ((rows_played++ & 3) == 0) show_position();
        for (tick = 0; tick < speed; tick++) {
            int n = RATE * 5 / (bpm * 2);                        /* frames per tick */
            if (tick) play_tick();
            mix(n);
            audio_write(out, n * 4);
            if ((pollkey() & 0xFF) == 27) goto done;
        }
        if (next_pos >= 0 || next_row >= 0) {                     /* B / D */
            int np = next_pos >= 0 ? next_pos : pos + 1;
            if (np <= pos && next_pos >= 0) break;                /* jumps back: the song's end */
            pos = np;
            row = next_row >= 0 && next_row < 64 ? next_row : 0;
            next_pos = next_row = -1;
        } else if (++row == 64) {
            row = 0;
            pos++;
        }
    }
done:
    audio_close();
    setcursor(23, 0);
    puts("\n");
    return 0;
}
