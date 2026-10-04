#ifndef LX_TIME_H
#define LX_TIME_H
#include <stddef.h>
typedef long long time_t;
struct tm { int tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst; long tm_gmtoff; const char *tm_zone; };
struct timespec { time_t tv_sec; long tv_nsec; };
time_t time(time_t *);
struct tm *localtime_r(const time_t *, struct tm *);
struct tm *gmtime_r(const time_t *, struct tm *);
#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1
int clock_gettime(int, struct timespec *);
#endif
