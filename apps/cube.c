/* cube.c - a spinning wireframe cube and a ring of dots around it,
 * in 640x480, with float math: sin, cos, a perspective divide.
 * Esc quits; arrows change the spin. */
#include "lexos.h"

#define W 640
#define H 480

static unsigned char frame[W * H];
static const float cube[8][3] = {
    {-1, -1, -1}, {1, -1, -1}, {1, 1, -1}, {-1, 1, -1},
    {-1, -1, 1}, {1, -1, 1}, {1, 1, 1}, {-1, 1, 1}
};
static const int edges[12][2] = {
    {0, 1}, {1, 2}, {2, 3}, {3, 0}, {4, 5}, {5, 6}, {6, 7}, {7, 4},
    {0, 4}, {1, 5}, {2, 6}, {3, 7}
};

static void line(int x0, int y0, int x1, int y1, int color)
{
    int dx = x1 > x0 ? x1 - x0 : x0 - x1, sx = x0 < x1 ? 1 : -1;
    int dy = y1 > y0 ? y0 - y1 : y1 - y0, sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    for (;;) {
        if (x0 >= 0 && x0 < W && y0 >= 0 && y0 < H) frame[y0 * W + x0] = color;
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

/* rotate (x, y, z) by angles a (around y) and b (around x), then project */
static void project(float x, float y, float z, float ca, float sa, float cb, float sb,
                    int *px, int *py, float *depth)
{
    float x1 = x * ca - z * sa, z1 = x * sa + z * ca;
    float y1 = y * cb - z1 * sb, z2 = y * sb + z1 * cb;
    float d = 4.0f / (z2 + 5.0f);                       /* perspective */
    *px = W / 2 + (int)(x1 * d * 110);
    *py = H / 2 + (int)(y1 * d * 110);
    *depth = z2;
}

int main(void)
{
    float a = 0, b = 0.4f, speed_a = 0.03f, speed_b = 0.017f;
    int i, px[8], py[8], k;
    unsigned next;
    if (gfx_mode_ex(W, H, 8) < 0) { puts("No 640x480 on this video card.\n"); return 1; }
    for (i = 0; i < 64; i++) gfx_palette(64 + i, RGB(i * 4, i * 3, 255));   /* dots: near = bright */
    next = millis();
    for (;;) {
        float ca = cos(a), sa = sin(a), cb = cos(b), sb = sin(b), dz;
        memset(frame, 0, sizeof frame);
        for (i = 0; i < 8; i++) project(cube[i][0], cube[i][1], cube[i][2], ca, sa, cb, sb, &px[i], &py[i], &dz);
        for (i = 0; i < 12; i++) line(px[edges[i][0]], py[edges[i][0]], px[edges[i][1]], py[edges[i][1]], 15);
        for (i = 0; i < 90; i++) {                      /* a ring of dots */
            float t = i * (float)(2 * M_PI / 90), x, y;
            int qx, qy, s;
            project(2.2f * cos(t), 0.3f * sin(3 * t + a * 4), 2.2f * sin(t), ca, sa, cb, sb, &qx, &qy, &dz);
            s = 64 + (int)((2.5f - dz) * 12);
            if (s < 64) s = 64;
            if (s > 127) s = 127;
            for (y = -1; y <= 1; y++) for (x = -1; x <= 1; x++)
                if (qx + x >= 0 && qx + x < W && qy + y >= 0 && qy + y < H) frame[(qy + (int)y) * W + qx + (int)x] = s;
        }
        gfx_blit(frame);
        a += speed_a;
        b += speed_b;
        k = pollkey();
        if ((k & 0xFF) == 27) break;
        if ((k >> 8) == KEY_LEFT) speed_a -= 0.01f;
        if ((k >> 8) == KEY_RIGHT) speed_a += 0.01f;
        if ((k >> 8) == KEY_UP) speed_b -= 0.01f;
        if ((k >> 8) == KEY_DOWN) speed_b += 0.01f;
        next += 16;
        sleep_until(next);
        if ((int)(millis() - next) > 100) next = millis();
    }
    gfx_mode(0);
    return 0;
}
