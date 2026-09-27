/* RINGS.C - graphics: 320x200, a byte per pixel. Esc quits. */
char frame[64000];

int main()
{
    int x, y, t = 0;
    gfx_mode(1);
    while ((pollkey() & 255) != 27) {
        for (y = 0; y < 200; y++)
            for (x = 0; x < 320; x++) {
                int dx = x - 160, dy = y - 100;
                frame[y * 320 + x] = 32 + ((dx * dx + dy * dy) / 64 + t) % 216;
            }
        gfx_blit(frame);
        t++;
        sleep_ms(20);
    }
    gfx_mode(0);
    return 0;
}
