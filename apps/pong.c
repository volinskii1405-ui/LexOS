/* pong.c - you (W/S or Up/Down) against LexOS, first to 5. Esc quits.
 * Shows graphics, keydown() for smooth, held-key movement, and
 * sleep_until() for a steady 60 frames a second. */
#include "lexos.h"

#define PADDLE_H 32
#define WIN 5

static unsigned char frame[GFX_W * GFX_H];

static void rect(int x, int y, int w, int h, int color)
{
    int i, j;
    for (j = y; j < y + h; j++)
        if (j >= 0 && j < GFX_H)
            for (i = x; i < x + w; i++)
                if (i >= 0 && i < GFX_W) frame[j * GFX_W + i] = color;
}

/* a digit 0-9 as 3x5 blocks */
static const unsigned short digits[10] = {
    0x7B6F, 0x2492, 0x73E7, 0x73CF, 0x5BC9, 0x79CF, 0x79EF, 0x7249, 0x7BEF, 0x7BCF
};
static void digit(int x, int y, int d, int color)
{
    int i;
    for (i = 0; i < 15; i++)
        if (digits[d] & (0x4000 >> i)) rect(x + i % 3 * 4, y + i / 3 * 4, 4, 4, color);
}

int main(void)
{
    int py = 84, cy = 84, bx, by, dx, dy, me = 0, cpu = 0, y;
    unsigned next;
    gfx_mode(1);
    next = millis();
    bx = 160 * 16; by = 100 * 16; dx = -32; dy = 16;         /* ball in 1/16 pixels */
    while (!keydown(KEY_ESC) && me < WIN && cpu < WIN) {
        if ((keydown(KEY_W) || keydown(KEY_UP)) && py > 0) py -= 3;
        if ((keydown(KEY_S) || keydown(KEY_DOWN)) && py < GFX_H - PADDLE_H) py += 3;
        if (cy + PADDLE_H / 2 < by / 16 - 4 && cy < GFX_H - PADDLE_H) cy += 2;  /* LexOS follows */
        if (cy + PADDLE_H / 2 > by / 16 + 4 && cy > 0) cy -= 2;

        bx += dx; by += dy;
        if (by < 0 || by > (GFX_H - 4) * 16) { dy = -dy; by += dy; beep(900, 5); }
        if (dx < 0 && bx / 16 <= 12 && bx / 16 >= 0 && by / 16 + 4 >= py && by / 16 <= py + PADDLE_H) {
            dx = -dx + 1; dy += (by / 16 - (py + PADDLE_H / 2)) / 4; beep(600, 10);
        }
        if (dx > 0 && bx / 16 >= GFX_W - 16 && bx / 16 <= GFX_W - 4 && by / 16 + 4 >= cy && by / 16 <= cy + PADDLE_H) {
            dx = -dx - 1; dy += (by / 16 - (cy + PADDLE_H / 2)) / 4; beep(600, 10);
        }
        if (dy > 28) dy = 28;
        if (dy < -28) dy = -28;
        if (bx < 0 || bx > GFX_W * 16) {                     /* a point */
            int lost = bx < 0;
            if (lost) cpu++; else me++;
            beep(lost ? 200 : 1200, 150);
            bx = 160 * 16; by = 100 * 16;
            dx = lost ? 32 : -32;                               /* serve to whoever scored */
            dy = (int)(millis() % 32) - 16;
        }

        memset(frame, 0, sizeof frame);
        for (y = 0; y < GFX_H; y += 10) rect(159, y, 2, 5, 8);
        digit(130, 10, me, RGB6(1, 5, 1));
        digit(180, 10, cpu, RGB6(5, 1, 1));
        rect(8, py, 4, PADDLE_H, 15);
        rect(GFX_W - 12, cy, 4, PADDLE_H, 15);
        rect(bx / 16, by / 16, 4, 4, RGB6(5, 5, 0));
        gfx_blit(frame);
        next += 16;                                          /* 60 frames a second */
        sleep_until(next);
        if ((int)(millis() - next) > 100) next = millis();   /* fell behind: don't rush */
    }
    gfx_mode(0);
    if (me == WIN) puts("You win!\n");
    else if (cpu == WIN) puts("LexOS wins.\n");
    return 0;
}
