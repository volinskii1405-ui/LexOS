/* lexos.h for the host: LexOS Web built as a Linux program by
 * tools/webtest/build.sh, to lay pages out and save them as pictures.
 * The system calls are hostlib.c's. */
#ifndef LEXOS_H
#define LEXOS_H
typedef __SIZE_TYPE__ size_t;
#define NULL ((void *)0)
#define RGB(r, g, b) ((unsigned)(r) << 16 | (unsigned)(g) << 8 | (unsigned)(b))
#define O_READ   0
#define O_WRITE  1
#define O_APPEND 2
#define O_UPDATE 3
#define KEY_ESC   0x01
#define KEY_CTRL  0x1D
#define KEY_LSHIFT 0x2A
#define KEY_RSHIFT 0x36
#define KEY_ENTER 0x1C
#define KEY_SPACE 0x39
#define KEY_UP    0x48
#define KEY_DOWN  0x50
#define KEY_LEFT  0x4B
#define KEY_RIGHT 0x4D
struct lx_dirent { char name[64]; int type; unsigned size; unsigned char time[8]; char sname[16]; };
#define LX_FILE    1
#define LX_DIR     2
#define LX_PROGRAM 3
void *memset(void *, int, size_t);
void *memcpy(void *, const void *, size_t);
void *memmove(void *, const void *, size_t);
int memcmp(const void *, const void *, size_t);
size_t strlen(const char *);
int strcmp(const char *, const char *);
char *strcpy(char *, const char *);
void *malloc(size_t);
void free(void *);
void *calloc(size_t, size_t);
void *realloc(void *, size_t);
int atoi(const char *);
double sqrt(double), sin(double), cos(double), tan(double), fabs(double), atan2(double, double), atan(double);
double log(double), exp(double), pow(double, double), floor(double), ceil(double);
int lxh_open(const char *, int); int lxh_read(int, void *, int); int lxh_fwrite(int, const void *, int);
int lxh_close(int); int lxh_seek(int, int); int lxh_fsize(int); int lxh_mkdir(const char *);
int lxh_readdir(const char *, int, struct lx_dirent *);
void lxh_exit(int); int lxh_write(const char *, int); void lxh_puts(const char *);
int lxh_gfx_mode_ex(int, int, int); void lxh_gfx_blit(const void *); void lxh_gfx_blit_rect(const void *, int, int, int, int);
void lxh_font(void *); void lxh_keymode(int); int lxh_pollkey(void); int lxh_mouse(int *); int lxh_inbox(char *, int);
int lxh_keydown(int); int lxh_clip_text_get(char *, int); int lxh_clip_text_set(const char *, int);
int lxh_tcp_open(const char *, int); int lxh_tcp_send(const void *, int); int lxh_tcp_recv(void *, int, int); void lxh_tcp_close(void);
unsigned lxh_millis(void); void lxh_sleep_ms(int); void lxh_notify(const char *);
#define open lxh_open
#define read lxh_read
#define fwrite lxh_fwrite
#define close lxh_close
#define seek lxh_seek
#define fsize lxh_fsize
#define mkdir lxh_mkdir
#define readdir lxh_readdir
#define exit lxh_exit
#define write lxh_write
#define puts lxh_puts
#define gfx_mode_ex lxh_gfx_mode_ex
#define gfx_blit lxh_gfx_blit
#define gfx_blit_rect lxh_gfx_blit_rect
#define font lxh_font
#define keymode lxh_keymode
#define pollkey lxh_pollkey
#define mouse lxh_mouse
#define inbox lxh_inbox
#define keydown lxh_keydown
#define clip_text_get lxh_clip_text_get
#define clip_text_set lxh_clip_text_set
#define tcp_open lxh_tcp_open
#define tcp_send lxh_tcp_send
#define tcp_recv lxh_tcp_recv
#define tcp_close lxh_tcp_close
#define millis lxh_millis
#define sleep_ms lxh_sleep_ms
#define notify lxh_notify
#endif
