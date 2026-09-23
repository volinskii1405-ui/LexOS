/* mandel.c - the Mandelbrot set in 800x600 true color.
 * Arrows move, + and - zoom, Esc quits. Shows gfx_mode_ex() and
 * gfx_blit_rect(): each row appears as soon as it's done.
 * Integer math only (fixed point, 1.0 = 1 << 24) - no FPU needed. */
#include "lexos.h"

#define W 800
#define H 600
#define ONE (1 << 24)
#define MAX_ITER 96

static unsigned frame[W * H];
static unsigned colors[MAX_ITER + 1];

static int mul(int a, int b) { return (int)(((long long)a * b) >> 24); }

static void draw(int cx, int cy, int scale)            /* scale: units per pixel */
{
    int x, y, i;
    for (y = 0; y < H; y++) {
        int ci = cy + (y - H / 2) * scale;
        for (x = 0; x < W; x++) {
            int cr = cx + (x - W / 2) * scale, zr = 0, zi = 0, zr2 = 0, zi2 = 0;
            for (i = 0; i < MAX_ITER && zr2 + zi2 < 4 * ONE; i++) {
                zi = 2 * mul(zr, zi) + ci;
                zr = zr2 - zi2 + cr;
                zr2 = mul(zr, zr);
                zi2 = mul(zi, zi);
            }
            frame[y * W + x] = colors[i];
        }
        gfx_blit_rect(frame, 0, y, W, 1);
        if (pollkey()) return;                             /* a key: start over */
    }
}

int main(void)
{
    int cx = -ONE / 2, cy = 0, scale = 3 * ONE / W, i, k;
    for (i = 0; i < MAX_ITER; i++) {                         /* blue -> white -> orange */
        int t = i * 255 / MAX_ITER;
        colors[i] = RGB(t < 128 ? t * 2 : 255, t < 170 ? t * 3 / 2 : 255, t < 64 ? 128 + t * 2 : 255 - t);
    }
    colors[MAX_ITER] = 0;
    if (gfx_mode_ex(W, H, 32) < 0) {
        puts("This machine's video can't do 800x600 in true color.\n");
        return 1;
    }
    for (;;) {
        draw(cx, cy, scale);
        k = getkey_full();
        if ((k & 0xFF) == 27) break;
        switch (k >> 8) {
        case KEY_LEFT:  cx -= scale * W / 4; break;
        case KEY_RIGHT: cx += scale * W / 4; break;
        case KEY_UP:    cy -= scale * H / 4; break;
        case KEY_DOWN:  cy += scale * H / 4; break;
        }
        if ((k & 0xFF) == '+' || (k & 0xFF) == '=') { if (scale > 4) scale /= 2; }
        if ((k & 0xFF) == '-') scale *= 2;
    }
    gfx_mode(0);
    return 0;
}
