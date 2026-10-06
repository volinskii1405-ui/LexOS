#ifndef LX_SYS_TIME_H
#define LX_SYS_TIME_H
#include <time.h>
struct timeval { time_t tv_sec; long tv_usec; };
int gettimeofday(struct timeval *, void *);
#endif
