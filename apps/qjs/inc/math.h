#ifndef LX_MATH_H
#define LX_MATH_H
#define NAN __builtin_nan("")
#define INFINITY __builtin_inf()
#define HUGE_VAL __builtin_huge_val()
#define isnan(x) __builtin_isnan(x)
#define isinf(x) __builtin_isinf(x)
#define isfinite(x) __builtin_isfinite(x)
#define signbit(x) __builtin_signbit(x)
#define fpclassify(x) __builtin_fpclassify(FP_NAN, FP_INFINITE, FP_NORMAL, FP_SUBNORMAL, FP_ZERO, x)
#define FP_NAN 0
#define FP_INFINITE 1
#define FP_ZERO 2
#define FP_SUBNORMAL 3
#define FP_NORMAL 4
#define M_PI 3.14159265358979323846
double acos(double), asin(double), atan(double), atan2(double, double), cos(double), sin(double), tan(double);
double cosh(double), sinh(double), tanh(double), acosh(double), asinh(double), atanh(double);
double exp(double), expm1(double), log(double), log10(double), log1p(double), log2(double);
double pow(double, double), sqrt(double), cbrt(double), hypot(double, double);
double ceil(double), floor(double), fabs(double), fmod(double, double), trunc(double), round(double), rint(double), nearbyint(double);
double fmin(double, double), fmax(double, double), copysign(double, double), ldexp(double, int), frexp(double, int *), scalbn(double, int);
double modf(double, double *);
long lrint(double);
long long llrint(double);
float fabsf(float), sqrtf(float), roundf(float), truncf(float), floorf(float), ceilf(float);
#endif
