/* p256.h - the NIST P-256 curve (secp256r1), for tls.h's key exchange:
 * p256_keygen(priv, pub) and p256_shared(out, priv, peer).
 *
 * Numbers mod p are 8 32-bit limbs (the lowest first), kept in
 * Montgomery form (times 2^256 mod p): a product is one fe_mmul. Points
 * are Jacobian (X, Y, Z: x = X/Z^2, y = Y/Z^3), Z = 0 the point at
 * infinity. Not constant-time - fine for a key used once. */
#ifndef LEXOS_P256_H
#define LEXOS_P256_H

typedef unsigned int p256_u32;
typedef unsigned long long p256_u64;
typedef p256_u32 fe[8];

static const fe P256_P = { 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 1, 0xFFFFFFFF };
static const fe P256_R2 = { 3, 0, 0xFFFFFFFF, 0xFFFFFFFB, 0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFFFFD, 4 };   /* 2^512 mod p */

static int fe_ge_p(const fe a)
{
    int i;
    for (i = 7; i >= 0; i--) {
        if (a[i] > P256_P[i]) return 1;
        if (a[i] < P256_P[i]) return 0;
    }
    return 1;
}
static void fe_sub_p(fe a)
{
    p256_u64 b = 0;
    int i;
    for (i = 0; i < 8; i++) {
        p256_u64 d = (p256_u64)a[i] - P256_P[i] - b;
        a[i] = (p256_u32)d;
        b = (d >> 32) & 1;
    }
}
static void fe_add(fe r, const fe a, const fe b)
{
    p256_u64 c = 0;
    int i;
    for (i = 0; i < 8; i++) { c += (p256_u64)a[i] + b[i]; r[i] = (p256_u32)c; c >>= 32; }
    if (c || fe_ge_p(r)) fe_sub_p(r);
}
static void fe_sub(fe r, const fe a, const fe b)
{
    p256_u64 bw = 0, c = 0;
    int i;
    for (i = 0; i < 8; i++) {
        p256_u64 d = (p256_u64)a[i] - b[i] - bw;
        r[i] = (p256_u32)d;
        bw = (d >> 32) & 1;
    }
    if (bw) for (i = 0; i < 8; i++) { c += (p256_u64)r[i] + P256_P[i]; r[i] = (p256_u32)c; c >>= 32; }
}
/* r = a * b / 2^256 mod p (-p^-1 mod 2^32 is 1) */
static void fe_mmul(fe r, const fe a, const fe b)
{
    p256_u32 t[10];
    int i, j;
    for (i = 0; i < 10; i++) t[i] = 0;
    for (i = 0; i < 8; i++) {
        p256_u64 c = 0;
        p256_u32 m;
        for (j = 0; j < 8; j++) { c += (p256_u64)t[j] + (p256_u64)a[j] * b[i]; t[j] = (p256_u32)c; c >>= 32; }
        c += t[8]; t[8] = (p256_u32)c; t[9] = (p256_u32)(c >> 32);
        m = t[0];
        c = ((p256_u64)t[0] + (p256_u64)m * P256_P[0]) >> 32;
        for (j = 1; j < 8; j++) { c += (p256_u64)t[j] + (p256_u64)m * P256_P[j]; t[j - 1] = (p256_u32)c; c >>= 32; }
        c += t[8]; t[7] = (p256_u32)c; c >>= 32;
        t[8] = t[9] + (p256_u32)c; t[9] = 0;
    }
    for (i = 0; i < 8; i++) r[i] = t[i];
    if (t[8] || fe_ge_p(r)) fe_sub_p(r);
}
static void fe_copy(fe r, const fe a) { int i; for (i = 0; i < 8; i++) r[i] = a[i]; }
static int fe_zero(const fe a) { int i; for (i = 0; i < 8; i++) if (a[i]) return 0; return 1; }
static void fe_mont(fe r, const fe a) { fe_mmul(r, a, P256_R2); }
static void fe_unmont(fe r, const fe a) { static const fe one = { 1 }; fe_mmul(r, a, one); }
/* r = a^(p-2) = 1/a (all in Montgomery form) */
static void fe_inv(fe r, const fe a)
{
    fe x;
    int i;
    static const fe pm2 = { 0xFFFFFFFD, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 1, 0xFFFFFFFF };
    static const fe one = { 1 };
    fe_mont(x, one);
    for (i = 255; i >= 0; i--) {
        fe_mmul(x, x, x);
        if (pm2[i >> 5] >> (i & 31) & 1) fe_mmul(x, x, a);
    }
    fe_copy(r, x);
}

struct p256_pt { fe x, y, z; };

static void p256_dbl(struct p256_pt *r, const struct p256_pt *p)
{
    fe delta, gamma, beta, alpha, t1, t2, x3, y3, z3;
    if (fe_zero(p->z)) { *r = *p; return; }
    fe_mmul(delta, p->z, p->z);
    fe_mmul(gamma, p->y, p->y);
    fe_mmul(beta, p->x, gamma);
    fe_sub(t1, p->x, delta);
    fe_add(t2, p->x, delta);
    fe_mmul(alpha, t1, t2);
    fe_add(t1, alpha, alpha); fe_add(alpha, t1, alpha);           /* 3(x-d)(x+d) */
    fe_mmul(x3, alpha, alpha);
    fe_add(t1, beta, beta); fe_add(t1, t1, t1); fe_add(t2, t1, t1); /* t1 = 4b, t2 = 8b */
    fe_sub(x3, x3, t2);
    fe_add(z3, p->y, p->z);
    fe_mmul(z3, z3, z3);
    fe_sub(z3, z3, gamma);
    fe_sub(z3, z3, delta);
    fe_sub(t1, t1, x3);
    fe_mmul(y3, alpha, t1);
    fe_mmul(t2, gamma, gamma);
    fe_add(t2, t2, t2); fe_add(t2, t2, t2); fe_add(t2, t2, t2);   /* 8 gamma^2 */
    fe_sub(y3, y3, t2);
    fe_copy(r->x, x3); fe_copy(r->y, y3); fe_copy(r->z, z3);
}
static void p256_add(struct p256_pt *r, const struct p256_pt *p, const struct p256_pt *q)
{
    fe z1z1, z2z2, u1, u2, s1, s2, h, i, j, rr, v, t, x3, y3, z3;
    if (fe_zero(p->z)) { *r = *q; return; }
    if (fe_zero(q->z)) { *r = *p; return; }
    fe_mmul(z1z1, p->z, p->z);
    fe_mmul(z2z2, q->z, q->z);
    fe_mmul(u1, p->x, z2z2);
    fe_mmul(u2, q->x, z1z1);
    fe_mmul(s1, p->y, q->z); fe_mmul(s1, s1, z2z2);
    fe_mmul(s2, q->y, p->z); fe_mmul(s2, s2, z1z1);
    fe_sub(h, u2, u1);
    fe_sub(rr, s2, s1);
    if (fe_zero(h)) {
        if (fe_zero(rr)) { p256_dbl(r, p); return; }
        { int k; for (k = 0; k < 8; k++) r->x[k] = r->y[k] = r->z[k] = 0; }
        return;
    }
    fe_add(i, h, h); fe_mmul(i, i, i);
    fe_mmul(j, h, i);
    fe_add(rr, rr, rr);
    fe_mmul(v, u1, i);
    fe_mmul(x3, rr, rr);
    fe_sub(x3, x3, j);
    fe_sub(x3, x3, v); fe_sub(x3, x3, v);
    fe_sub(t, v, x3);
    fe_mmul(y3, rr, t);
    fe_mmul(t, s1, j); fe_add(t, t, t);
    fe_sub(y3, y3, t);
    fe_add(z3, p->z, q->z);
    fe_mmul(z3, z3, z3);
    fe_sub(z3, z3, z1z1);
    fe_sub(z3, z3, z2z2);
    fe_mmul(z3, z3, h);
    fe_copy(r->x, x3); fe_copy(r->y, y3); fe_copy(r->z, z3);
}
static void p256_from_bytes(fe r, const unsigned char *b)    /* 32 bytes, big-endian */
{
    int i;
    for (i = 0; i < 8; i++)
        r[i] = (p256_u32)b[31 - 4 * i] | (p256_u32)b[30 - 4 * i] << 8 | (p256_u32)b[29 - 4 * i] << 16 | (p256_u32)b[28 - 4 * i] << 24;
}
static void p256_to_bytes(unsigned char *b, const fe a)
{
    int i;
    for (i = 0; i < 8; i++) {
        b[31 - 4 * i] = a[i]; b[30 - 4 * i] = a[i] >> 8; b[29 - 4 * i] = a[i] >> 16; b[28 - 4 * i] = a[i] >> 24;
    }
}
/* out (65 bytes: 04 x y) = k * (x, y) - pt given as 65 bytes, or 0 for
 * the curve's generator; 0 if the result's the point at infinity */
static int p256_mul(unsigned char out[65], const unsigned char k[32], const unsigned char *pt)
{
    static const unsigned char g[65] = { 4,
        0x6B, 0x17, 0xD1, 0xF2, 0xE1, 0x2C, 0x42, 0x47, 0xF8, 0xBC, 0xE6, 0xE5, 0x63, 0xA4, 0x40, 0xF2,
        0x77, 0x03, 0x7D, 0x81, 0x2D, 0xEB, 0x33, 0xA0, 0xF4, 0xA1, 0x39, 0x45, 0xD8, 0x98, 0xC2, 0x96,
        0x4F, 0xE3, 0x42, 0xE2, 0xFE, 0x1A, 0x7F, 0x9B, 0x8E, 0xE7, 0xEB, 0x4A, 0x7C, 0x0F, 0x9E, 0x16,
        0x2B, 0xCE, 0x33, 0x57, 0x6B, 0x31, 0x5E, 0xCE, 0xCB, 0xB6, 0x40, 0x68, 0x37, 0xBF, 0x51, 0xF5 };
    static const fe one = { 1 };
    struct p256_pt base, acc;
    fe zi, zi2, x, y;
    int i;
    if (!pt) pt = g;
    if (pt[0] != 4) return 0;
    p256_from_bytes(x, pt + 1); p256_from_bytes(y, pt + 33);
    if (fe_ge_p(x) || fe_ge_p(y)) return 0;
    fe_mont(base.x, x); fe_mont(base.y, y); fe_mont(base.z, one);
    {                                                    /* on the curve? y^2 = x^3 - 3x + b */
        static const unsigned char bb[32] = {
            0x5A, 0xC6, 0x35, 0xD8, 0xAA, 0x3A, 0x93, 0xE7, 0xB3, 0xEB, 0xBD, 0x55, 0x76, 0x98, 0x86, 0xBC,
            0x65, 0x1D, 0x06, 0xB0, 0xCC, 0x53, 0xB0, 0xF6, 0x3B, 0xCE, 0x3C, 0x3E, 0x27, 0xD2, 0x60, 0x4B };
        fe l, rhs, t, b;
        p256_from_bytes(t, bb); fe_mont(b, t);
        fe_mmul(l, base.y, base.y);
        fe_mmul(rhs, base.x, base.x); fe_mmul(rhs, rhs, base.x);
        fe_sub(rhs, rhs, base.x); fe_sub(rhs, rhs, base.x); fe_sub(rhs, rhs, base.x);
        fe_add(rhs, rhs, b);
        for (i = 0; i < 8; i++) if (l[i] != rhs[i]) return 0;
    }
    for (i = 0; i < 8; i++) acc.x[i] = acc.y[i] = acc.z[i] = 0;
    for (i = 255; i >= 0; i--) {
        p256_dbl(&acc, &acc);
        if (k[31 - (i >> 3)] >> (i & 7) & 1) p256_add(&acc, &acc, &base);
    }
    if (fe_zero(acc.z)) return 0;
    fe_inv(zi, acc.z);
    fe_mmul(zi2, zi, zi);
    fe_mmul(x, acc.x, zi2);
    fe_mmul(zi2, zi2, zi);
    fe_mmul(y, acc.y, zi2);
    fe_unmont(x, x); fe_unmont(y, y);
    out[0] = 4;
    p256_to_bytes(out + 1, x);
    p256_to_bytes(out + 33, y);
    return 1;
}

#endif
