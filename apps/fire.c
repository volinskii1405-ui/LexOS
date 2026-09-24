/* fire.c - the classic demo-scene fire, in 320x200 graphics.
 * Any key quits. Shows gfx_mode/gfx_palette/gfx_blit. */
#include "lexos.h"

static unsigned char heat[GFX_H + 2][GFX_W];
static unsigned char frame[GFX_W * GFX_H];
static unsigned seed = 1;

static unsigned rnd(void) { seed = seed * 1103515245u + 12345u; return seed >> 16; }

int main(void)
{
    int x, y, i;
    unsigned next;
    gfx_mode(1);
    for (i = 0; i < 256; i++) {            /* black -> red -> yellow -> white */
        unsigned r = i < 85 ? i * 3 : 255;
        unsigned g = i < 85 ? 0 : i < 170 ? (i - 85) * 3 : 255;
        unsigned b = i < 170 ? 0 : (i - 170) * 3;
        gfx_palette(i, r << 16 | g << 8 | b);
    }
    seed = ticks();
    next = millis();
    while (!pollkey()) {
        for (x = 0; x < GFX_W; x++)         /* new sparks along the bottom */
            heat[GFX_H + 1][x] = heat[GFX_H][x] = rnd() % 3 ? 255 : 40;
        for (y = 0; y < GFX_H; y++)         /* each pixel: its neighbors below, cooled */
            for (x = 0; x < GFX_W; x++) {
                int l = x ? x - 1 : x, r = x < GFX_W - 1 ? x + 1 : x;
                int v = (heat[y + 1][l] + heat[y + 1][x] + heat[y + 1][r] + heat[y + 2][x]) * 16 / 65;
                heat[y][x] = v > 0 ? v - (v > 2) : 0;
            }
        for (y = 0; y < GFX_H; y++)
            memcpy(frame + y * GFX_W, heat[y], GFX_W);
        gfx_blit(frame);
        next += 16;                         /* up to 60 frames a second */
        sleep_until(next);
        if ((int)(millis() - next) > 100) next = millis();   /* fell behind: don't rush */
    }
    gfx_mode(0);
    return 0;
}
