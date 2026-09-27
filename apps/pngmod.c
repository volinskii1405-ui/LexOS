/* pngmod.c - png.h as a piece of the kernel: /SYSTEM/PNG.BIN, loaded
 * at KPNG_BASE (src/dkpng.asm) at boot, called from assembly with the
 * C convention. It starts with "PNGM" and then its functions:
 *
 *   +4  png_to_bmp(in, n, out, max, max_w, max_h)
 *
 * No system calls - it runs in the kernel, on the caller's stack. */
typedef unsigned int size_t;

/* (gcc may call these on its own) */
void *memset(void *d, int c, size_t n) { unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void *memcpy(void *d, const void *s, size_t n) { unsigned char *p = d; const unsigned char *q = s; while (n--) *p++ = *q++; return d; }

#include "png.h"

__attribute__((section(".entry"), used))
const unsigned pngmod_head[2] = { 0x4D474E50, (unsigned)png_to_bmp };      /* "PNGM" */
