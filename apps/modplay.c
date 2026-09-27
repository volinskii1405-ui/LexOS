/* modplay.c - plays ProTracker .MOD music: run modplay.app SONG.MOD
 * (the engine: mod.h), streamed to the Sound Blaster with audio_write().
 * Esc stops. */
#include "mod.h"

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
    int i, fd, size, n, last_row = -1;
    unsigned char *buf;
    if (argc < 2) { puts("Usage: run modplay.app SONG.MOD   (Esc stops)\n"); return 1; }
    fd = open(argv[1], O_READ);
    if (fd < 0) { puts("Can't open "); puts(argv[1]); putchar('\n'); return 1; }
    size = fsize(fd);
    buf = malloc(size + 1);
    if (!buf) { puts("Too big for memory.\n"); close(fd); return 1; }
    read(fd, buf, size);
    close(fd);
    if (!mod_open(buf, size)) { puts("Not a 4-channel ProTracker module.\n"); return 1; }
    if (audio_open(RATE, 2) < 0) { puts("No sound card (QEMU: -device sb16).\n"); return 1; }

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

    while ((n = mod_tick(0))) {
        if (row != last_row && (row & 3) == 0) { show_position(); last_row = row; }
        audio_write(out, n * 4);
        if ((pollkey() & 0xFF) == 27) break;
    }
    audio_close();
    setcursor(23, 0);
    puts("\n");
    return 0;
}
