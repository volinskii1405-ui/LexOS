/* mod.h - a ProTracker .MOD player's engine, for LexOS programs in C:
 * four channels mixed in software into 16-bit stereo at RATE (22050Hz).
 *
 *   mod_open(buf, size)   the module (kept where it is) -> 1 if it is one
 *   mod_tick(0)           the next tick into out[] -> its frames (0: the end)
 *   mod_length()          the song's length in frames
 *   mod_seek(frame)       from somewhere else in it (mod_frames: where)
 *
 * The usual effects: arpeggio, portamento (up/down/to note), vibrato,
 * volume slides, sample offset, jumps and breaks, speed and tempo,
 * and the fine slides / note cut of the E commands. Integer math only. */
#ifndef MOD_H
#define MOD_H
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
static int speed = 6, bpm = 125, tick, row, pos, next_row = -1, next_pos = -1, mod_ended;
static unsigned mod_frames;                             /* played so far */
static unsigned step_k;                                 /* (PAL_CLOCK << 8) / RATE */
static short out[RATE / 10 * 2 + 8];                    /* one tick at the slowest tempo */
#define MOD_TICK_MAX (RATE / 10 + 4)                    /* (its frames) */

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

/* back to its start */
static void mod_restart(void)
{
    memset(ch, 0, sizeof ch);
    speed = 6; bpm = 125; tick = 0; row = 0; pos = 0;
    next_row = next_pos = -1;
    mod_ended = 0; mod_frames = 0;
}

/* the module at buf (size bytes, kept) -> 1, or 0 if it isn't one */
static int mod_open(unsigned char *buf, int size)
{
    int i, off;
    mod = buf;
    mod_size = size;
    if (mod_size < 1084 || (memcmp(mod + 1080, "M.K.", 4) && memcmp(mod + 1080, "4CHN", 4)
        && memcmp(mod + 1080, "FLT4", 4) && memcmp(mod + 1080, "M!K!", 4)))
        return 0;
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
    step_k = (PAL_CLOCK << 8) / RATE;
    mod_restart();
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

/* n frames without the sound (for finding a place, or the length):
 * the channels just move on */
static void mix_dry(int n)
{
    int i;
    for (i = 0; i < CHANNELS; i++) {
        struct channel *c = &ch[i];
        struct sample *s = c->smp;
        unsigned adv;
        if (!c->active || !s || !s->len) continue;
        adv = c->frac + c->step * (unsigned)n;
        c->pos += adv >> 16;
        c->frac = adv & 0xFFFF;
        if (c->pos >= s->len || (s->loop_len && c->pos >= s->loop_start + s->loop_len)) {
            if (s->loop_len) c->pos = s->loop_start + (c->pos - s->loop_start) % s->loop_len;
            else c->active = 0;
        }
    }
}

/* the next tick: into out[] (left, right; unless dry) -> its frames,
 * 0 once the song's over (its end, or a jump back to where it was) */
static int mod_tick(int dry)
{
    int n;
    if (mod_ended || pos >= song_len) { mod_ended = 1; return 0; }
    if (tick == 0) play_row(); else play_tick();
    n = RATE * 5 / (bpm * 2);                               /* frames per tick */
    if (dry) mix_dry(n); else mix(n);
    mod_frames += n;
    if (++tick >= speed) {
        tick = 0;
        if (next_pos >= 0 || next_row >= 0) {               /* B / D */
            int np = next_pos >= 0 ? next_pos : pos + 1;
            if (np <= pos && next_pos >= 0) mod_ended = 1;  /* jumps back: the song's end */
            pos = np;
            row = next_row >= 0 && next_row < 64 ? next_row : 0;
            next_pos = next_row = -1;
        } else if (++row == 64) {
            row = 0;
            pos++;
        }
    }
    return n;
}

/* the song's length, in frames (played through, silently) */
static __attribute__((unused)) unsigned mod_length(void)
{
    unsigned total;
    int guard = 0;
    mod_restart();
    while (mod_tick(1) && guard++ < 200000);
    total = mod_frames;
    mod_restart();
    return total;
}

/* to frame f (from the start, silently) */
static __attribute__((unused)) void mod_seek(unsigned f)
{
    mod_restart();
    while (mod_frames + MOD_TICK_MAX < f && mod_tick(1));
}

#endif
