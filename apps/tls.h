/* tls.h - TLS 1.3 for LexOS programs (LexOS Web's https://).
 *
 *   int n = tls_get("example.com", 443, "/", buf, size);
 *
 * opens a TCP connection (the kernel's: tcp_open & co., lexos.h), does
 * a TLS 1.3 handshake, sends an HTTP/1.1 GET (Connection: close) and reads the whole answer
 * - headers and body - into buf: its length, or <0 (tls_error says why).
 *
 * All of it is here, in C, from the standards: X25519 key exchange
 * (RFC 7748, after TweetNaCl), SHA-256, HMAC and HKDF (the TLS 1.3 key
 * schedule, RFC 8446), and two ciphers: AES-128-GCM and
 * ChaCha20-Poly1305 (RFC 8439). The connection is encrypted and its
 * handshake checked (the server's Finished) - but the server's
 * certificate isn't: LexOS has no list of certificate authorities to
 * check it against, so anyone in the middle could pretend to be the
 * server. Good for reading the web; don't type secrets into it. */
#ifndef LEXOS_TLS_H
#define LEXOS_TLS_H

typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long long u64;
typedef long long i64;

static const char *tls_error = "";

/* ============================================================
 * SHA-256
 * ============================================================ */
struct sha256 { u32 h[8]; u8 buf[64]; u32 n; u64 len; };
static const u32 sha_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2 };
#define ROR(x, n) ((x) >> (n) | (x) << (32 - (n)))

static void sha_block(struct sha256 *s, const u8 *p)
{
    u32 w[64], a, b, c, d, e, f, g, h, t1, t2;
    int i;
    for (i = 0; i < 16; i++) w[i] = (u32)p[4 * i] << 24 | p[4 * i + 1] << 16 | p[4 * i + 2] << 8 | p[4 * i + 3];
    for (; i < 64; i++) {
        u32 s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        u32 s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3]; e = s->h[4]; f = s->h[5]; g = s->h[6]; h = s->h[7];
    for (i = 0; i < 64; i++) {
        t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + sha_k[i] + w[i];
        t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d;
    s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}

static void sha_init(struct sha256 *s)
{
    static const u32 iv[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                               0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
    int i;
    for (i = 0; i < 8; i++) s->h[i] = iv[i];
    s->n = 0;
    s->len = 0;
}

static void sha_update(struct sha256 *s, const void *data, int len)
{
    const u8 *p = data;
    s->len += len;
    while (len > 0) {
        s->buf[s->n++] = *p++;
        len--;
        if (s->n == 64) { sha_block(s, s->buf); s->n = 0; }
    }
}

static void sha_final(struct sha256 *s, u8 out[32])
{
    u64 bits = s->len * 8;
    int i;
    u8 pad = 0x80;
    sha_update(s, &pad, 1);
    pad = 0;
    while (s->n != 56) sha_update(s, &pad, 1);
    for (i = 7; i >= 0; i--) { u8 b = (u8)(bits >> (8 * i)); sha_update(s, &b, 1); }
    for (i = 0; i < 8; i++) {
        out[4 * i] = s->h[i] >> 24; out[4 * i + 1] = s->h[i] >> 16;
        out[4 * i + 2] = s->h[i] >> 8; out[4 * i + 3] = s->h[i];
    }
}

static void hmac(const u8 *key, int klen, const u8 *msg, int mlen, u8 out[32])
{
    struct sha256 s;
    u8 k[64], ih[32];
    int i;
    memset(k, 0, 64);
    if (klen > 64) { sha_init(&s); sha_update(&s, key, klen); sha_final(&s, k); }
    else memcpy(k, key, klen);
    for (i = 0; i < 64; i++) k[i] ^= 0x36;
    sha_init(&s); sha_update(&s, k, 64); sha_update(&s, msg, mlen); sha_final(&s, ih);
    for (i = 0; i < 64; i++) k[i] ^= 0x36 ^ 0x5c;
    sha_init(&s); sha_update(&s, k, 64); sha_update(&s, ih, 32); sha_final(&s, out);
}

/* HKDF-Expand-Label(secret, label, context, len) - len at most 32 */
static void expand_label(const u8 secret[32], const char *label, const u8 *ctx, int clen, u8 *out, int len)
{
    u8 info[100], t[32];
    int n = 0, l = strlen(label);
    info[n++] = 0; info[n++] = len;
    info[n++] = 6 + l;
    memcpy(info + n, "tls13 ", 6); n += 6;
    memcpy(info + n, label, l); n += l;
    info[n++] = clen;
    memcpy(info + n, ctx, clen); n += clen;
    info[n++] = 1;
    hmac(secret, 32, info, n, t);
    memcpy(out, t, len);
}

/* ============================================================
 * X25519 (after TweetNaCl)
 * ============================================================ */
typedef i64 gf[16];
static const gf gf_121665 = { 0xDB41, 1 };

static void car25519(gf o)
{
    int i;
    i64 c;
    for (i = 0; i < 16; i++) {
        o[i] += (1LL << 16);
        c = o[i] >> 16;
        o[(i + 1) * (i < 15)] += c - 1 + 37 * (c - 1) * (i == 15);
        o[i] -= c * 65536;
    }
}
static void sel25519(gf p, gf q, int b)
{
    i64 t, c = ~(i64)(b - 1);
    int i;
    for (i = 0; i < 16; i++) { t = c & (p[i] ^ q[i]); p[i] ^= t; q[i] ^= t; }
}
static void pack25519(u8 *o, const gf n)
{
    int i, j, b;
    gf m, t;
    for (i = 0; i < 16; i++) t[i] = n[i];
    car25519(t); car25519(t); car25519(t);
    for (j = 0; j < 2; j++) {
        m[0] = t[0] - 0xffed;
        for (i = 1; i < 15; i++) { m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1); m[i - 1] &= 0xffff; }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
        b = (m[15] >> 16) & 1;
        m[14] &= 0xffff;
        sel25519(t, m, 1 - b);
    }
    for (i = 0; i < 16; i++) { o[2 * i] = t[i] & 0xff; o[2 * i + 1] = t[i] >> 8; }
}
static void unpack25519(gf o, const u8 *n)
{
    int i;
    for (i = 0; i < 16; i++) o[i] = n[2 * i] + ((i64)n[2 * i + 1] << 8);
    o[15] &= 0x7fff;
}
static void fA(gf o, const gf a, const gf b) { int i; for (i = 0; i < 16; i++) o[i] = a[i] + b[i]; }
static void fZ(gf o, const gf a, const gf b) { int i; for (i = 0; i < 16; i++) o[i] = a[i] - b[i]; }
static void fM(gf o, const gf a, const gf b)
{
    i64 t[31];
    int i, j;
    for (i = 0; i < 31; i++) t[i] = 0;
    for (i = 0; i < 16; i++) for (j = 0; j < 16; j++) t[i + j] += a[i] * b[j];
    for (i = 0; i < 15; i++) t[i] += 38 * t[i + 16];
    for (i = 0; i < 16; i++) o[i] = t[i];
    car25519(o); car25519(o);
}
static void fS(gf o, const gf a) { fM(o, a, a); }
static void inv25519(gf o, const gf in)
{
    gf c;
    int a;
    for (a = 0; a < 16; a++) c[a] = in[a];
    for (a = 253; a >= 0; a--) { fS(c, c); if (a != 2 && a != 4) fM(c, c, in); }
    for (a = 0; a < 16; a++) o[a] = c[a];
}
static void x25519(u8 q[32], const u8 n[32], const u8 p[32])
{
    u8 z[32];
    i64 x[80];
    int r, i;
    gf a, b, c, d, e, f;
    for (i = 0; i < 31; i++) z[i] = n[i];
    z[31] = (n[31] & 127) | 64;
    z[0] &= 248;
    unpack25519(x, p);
    for (i = 0; i < 16; i++) { b[i] = x[i]; d[i] = a[i] = c[i] = 0; }
    a[0] = d[0] = 1;
    for (i = 254; i >= 0; --i) {
        r = (z[i >> 3] >> (i & 7)) & 1;
        sel25519(a, b, r); sel25519(c, d, r);
        fA(e, a, c); fZ(a, a, c); fA(c, b, d); fZ(b, b, d); fS(d, e); fS(f, a);
        fM(a, c, a); fM(c, b, e); fA(e, a, c); fZ(a, a, c); fS(b, a); fZ(c, d, f);
        fM(a, c, gf_121665); fA(a, a, d); fM(c, c, a); fM(a, d, f); fM(d, b, x); fS(b, e);
        sel25519(a, b, r); sel25519(c, d, r);
    }
    for (i = 0; i < 16; i++) { x[i + 16] = a[i]; x[i + 32] = c[i]; x[i + 48] = b[i]; x[i + 64] = d[i]; }
    inv25519(x + 32, x + 32);
    fM(x + 16, x + 16, x + 32);
    pack25519(q, x + 16);
}

/* ============================================================
 * AES-128 and GCM
 * ============================================================ */
static u8 aes_sbox[256];
static void aes_tables(void)
{
    /* the S-box, worked out: the inverse in GF(2^8), then the affine map */
    u8 p = 1, q = 1;
    if (aes_sbox[0]) return;
    do {
        u8 x;
        p = p ^ (p << 1) ^ (p & 0x80 ? 0x1B : 0);
        q ^= q << 1; q ^= q << 2; q ^= q << 4;
        if (q & 0x80) q ^= 0x09;
        x = q ^ (q << 1 | q >> 7) ^ (q << 2 | q >> 6) ^ (q << 3 | q >> 5) ^ (q << 4 | q >> 4);
        aes_sbox[p] = x ^ 0x63;
    } while (p != 1);
    aes_sbox[0] = 0x63;
}

struct aes { u8 rk[176]; };
static void aes_key(struct aes *a, const u8 key[16])
{
    int i;
    u8 rcon = 1;
    aes_tables();
    memcpy(a->rk, key, 16);
    for (i = 16; i < 176; i += 4) {
        u8 t[4];
        memcpy(t, a->rk + i - 4, 4);
        if (i % 16 == 0) {
            u8 u = t[0];
            t[0] = aes_sbox[t[1]] ^ rcon; t[1] = aes_sbox[t[2]]; t[2] = aes_sbox[t[3]]; t[3] = aes_sbox[u];
            rcon = rcon << 1 ^ (rcon & 0x80 ? 0x1B : 0);
        }
        a->rk[i] = a->rk[i - 16] ^ t[0]; a->rk[i + 1] = a->rk[i - 15] ^ t[1];
        a->rk[i + 2] = a->rk[i - 14] ^ t[2]; a->rk[i + 3] = a->rk[i - 13] ^ t[3];
    }
}
static u8 xt(u8 x) { return x << 1 ^ (x & 0x80 ? 0x1B : 0); }
static void aes_block(const struct aes *a, const u8 in[16], u8 out[16])
{
    u8 s[16], t[16];
    int r, i, c;
    for (i = 0; i < 16; i++) s[i] = in[i] ^ a->rk[i];
    for (r = 1; r <= 10; r++) {
        for (i = 0; i < 16; i++) t[i] = aes_sbox[s[(i + 4 * (i % 4)) % 16]];   /* SubBytes, ShiftRows */
        if (r < 10)
            for (c = 0; c < 4; c++) {                                          /* MixColumns */
                u8 *m = t + 4 * c, a0 = m[0], a1 = m[1], a2 = m[2], a3 = m[3], all = a0 ^ a1 ^ a2 ^ a3;
                m[0] ^= all ^ xt(a0 ^ a1); m[1] ^= all ^ xt(a1 ^ a2);
                m[2] ^= all ^ xt(a2 ^ a3); m[3] ^= all ^ xt(a3 ^ a0);
            }
        for (i = 0; i < 16; i++) s[i] = t[i] ^ a->rk[16 * r + i];
    }
    memcpy(out, s, 16);
}

/* x = x * h in GF(2^128) (GCM's bit order) */
static void gf_mul(u8 x[16], const u8 h[16])
{
    u8 z[16], v[16];
    int i, j;
    memset(z, 0, 16);
    memcpy(v, h, 16);
    for (i = 0; i < 128; i++) {
        if (x[i / 8] & (0x80 >> (i % 8))) for (j = 0; j < 16; j++) z[j] ^= v[j];
        {
            int lsb = v[15] & 1;
            for (j = 15; j > 0; j--) v[j] = v[j] >> 1 | v[j - 1] << 7;
            v[0] >>= 1;
            if (lsb) v[0] ^= 0xE1;
        }
    }
    memcpy(x, z, 16);
}
static void ghash(u8 y[16], const u8 h[16], const u8 *d, int n)
{
    while (n > 0) {
        int k = n < 16 ? n : 16, i;
        for (i = 0; i < k; i++) y[i] ^= d[i];
        gf_mul(y, h);
        d += k;
        n -= k;
    }
}

/* AES-128-GCM: encrypt (dec=0) or decrypt and check (dec=1) n bytes in
 * place; tag: written, or checked (-> 0 bad, 1 good) */
static int gcm(const u8 key[16], const u8 iv[12], const u8 *aad, int alen, u8 *p, int n, u8 tag[16], int dec)
{
    struct aes a;
    u8 h[16], j[16], ctr[16], ks[16], y[16], lens[16];
    int i, k;
    u32 c = 2;
    aes_key(&a, key);
    memset(h, 0, 16);
    aes_block(&a, h, h);
    memcpy(j, iv, 12); j[12] = j[13] = j[14] = 0; j[15] = 1;
    memset(y, 0, 16);
    ghash(y, h, aad, alen);
    if (dec) ghash(y, h, p, n);
    for (i = 0; i < n; i += 16) {
        memcpy(ctr, iv, 12);
        ctr[12] = c >> 24; ctr[13] = c >> 16; ctr[14] = c >> 8; ctr[15] = c;
        c++;
        aes_block(&a, ctr, ks);
        for (k = 0; k < 16 && i + k < n; k++) p[i + k] ^= ks[k];
    }
    if (!dec) ghash(y, h, p, n);
    memset(lens, 0, 16);
    {
        u64 ab = (u64)alen * 8, cb = (u64)n * 8;
        for (i = 0; i < 8; i++) { lens[7 - i] = ab >> (8 * i); lens[15 - i] = cb >> (8 * i); }
    }
    ghash(y, h, lens, 16);
    aes_block(&a, j, ks);
    for (i = 0; i < 16; i++) y[i] ^= ks[i];
    if (!dec) { memcpy(tag, y, 16); return 1; }
    k = 0;
    for (i = 0; i < 16; i++) k |= y[i] ^ tag[i];
    return k == 0;
}

/* ============================================================
 * ChaCha20-Poly1305
 * ============================================================ */
#define QR(a, b, c, d) a += b; d ^= a; d = d << 16 | d >> 16; c += d; b ^= c; b = b << 12 | b >> 20; \
                       a += b; d ^= a; d = d << 8 | d >> 24; c += d; b ^= c; b = b << 7 | b >> 25;
static u32 le32(const u8 *p) { return p[0] | p[1] << 8 | p[2] << 16 | (u32)p[3] << 24; }
static void chacha_block(const u8 key[32], u32 counter, const u8 nonce[12], u8 out[64])
{
    u32 s[16], x[16];
    int i;
    s[0] = 0x61707865; s[1] = 0x3320646e; s[2] = 0x79622d32; s[3] = 0x6b206574;
    for (i = 0; i < 8; i++) s[4 + i] = le32(key + 4 * i);
    s[12] = counter;
    for (i = 0; i < 3; i++) s[13 + i] = le32(nonce + 4 * i);
    memcpy(x, s, sizeof x);
    for (i = 0; i < 10; i++) {
        QR(x[0], x[4], x[8], x[12]) QR(x[1], x[5], x[9], x[13])
        QR(x[2], x[6], x[10], x[14]) QR(x[3], x[7], x[11], x[15])
        QR(x[0], x[5], x[10], x[15]) QR(x[1], x[6], x[11], x[12])
        QR(x[2], x[7], x[8], x[13]) QR(x[3], x[4], x[9], x[14])
    }
    for (i = 0; i < 16; i++) {
        u32 v = x[i] + s[i];
        out[4 * i] = v; out[4 * i + 1] = v >> 8; out[4 * i + 2] = v >> 16; out[4 * i + 3] = v >> 24;
    }
}

struct poly { u32 r[5], h[5], pad[4]; };
static void poly_blocks(struct poly *st, const u8 *m, int n)
{
    u32 r0 = st->r[0], r1 = st->r[1], r2 = st->r[2], r3 = st->r[3], r4 = st->r[4];
    u32 s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;
    u32 h0 = st->h[0], h1 = st->h[1], h2 = st->h[2], h3 = st->h[3], h4 = st->h[4];
    while (n > 0) {
        u8 b[16];
        u32 hibit = 1 << 24, c;
        u64 d0, d1, d2, d3, d4;
        if (n >= 16) memcpy(b, m, 16);
        else { memset(b, 0, 16); memcpy(b, m, n); b[n] = 1; hibit = 0; }
        h0 += le32(b) & 0x3ffffff;
        h1 += (le32(b + 3) >> 2) & 0x3ffffff;
        h2 += (le32(b + 6) >> 4) & 0x3ffffff;
        h3 += (le32(b + 9) >> 6) & 0x3ffffff;
        h4 += (le32(b + 12) >> 8) | hibit;
        d0 = (u64)h0 * r0 + (u64)h1 * s4 + (u64)h2 * s3 + (u64)h3 * s2 + (u64)h4 * s1;
        d1 = (u64)h0 * r1 + (u64)h1 * r0 + (u64)h2 * s4 + (u64)h3 * s3 + (u64)h4 * s2;
        d2 = (u64)h0 * r2 + (u64)h1 * r1 + (u64)h2 * r0 + (u64)h3 * s4 + (u64)h4 * s3;
        d3 = (u64)h0 * r3 + (u64)h1 * r2 + (u64)h2 * r1 + (u64)h3 * r0 + (u64)h4 * s4;
        d4 = (u64)h0 * r4 + (u64)h1 * r3 + (u64)h2 * r2 + (u64)h3 * r1 + (u64)h4 * r0;
        c = (u32)(d0 >> 26); h0 = (u32)d0 & 0x3ffffff;
        d1 += c; c = (u32)(d1 >> 26); h1 = (u32)d1 & 0x3ffffff;
        d2 += c; c = (u32)(d2 >> 26); h2 = (u32)d2 & 0x3ffffff;
        d3 += c; c = (u32)(d3 >> 26); h3 = (u32)d3 & 0x3ffffff;
        d4 += c; c = (u32)(d4 >> 26); h4 = (u32)d4 & 0x3ffffff;
        h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff; h1 += c;
        m += 16;
        n -= 16;
    }
    st->h[0] = h0; st->h[1] = h1; st->h[2] = h2; st->h[3] = h3; st->h[4] = h4;
}
static void poly_init(struct poly *st, const u8 key[32])
{
    st->r[0] = le32(key) & 0x3ffffff;
    st->r[1] = (le32(key + 3) >> 2) & 0x3ffff03;
    st->r[2] = (le32(key + 6) >> 4) & 0x3ffc0ff;
    st->r[3] = (le32(key + 9) >> 6) & 0x3f03fff;
    st->r[4] = (le32(key + 12) >> 8) & 0x00fffff;
    st->h[0] = st->h[1] = st->h[2] = st->h[3] = st->h[4] = 0;
    st->pad[0] = le32(key + 16); st->pad[1] = le32(key + 20);
    st->pad[2] = le32(key + 24); st->pad[3] = le32(key + 28);
}
static void poly_final(struct poly *st, u8 mac[16])
{
    u32 h0 = st->h[0], h1 = st->h[1], h2 = st->h[2], h3 = st->h[3], h4 = st->h[4], c, g0, g1, g2, g3, g4, mask;
    u64 f;
    c = h1 >> 26; h1 &= 0x3ffffff; h2 += c;
    c = h2 >> 26; h2 &= 0x3ffffff; h3 += c;
    c = h3 >> 26; h3 &= 0x3ffffff; h4 += c;
    c = h4 >> 26; h4 &= 0x3ffffff; h0 += c * 5;
    c = h0 >> 26; h0 &= 0x3ffffff; h1 += c;
    g0 = h0 + 5; c = g0 >> 26; g0 &= 0x3ffffff;
    g1 = h1 + c; c = g1 >> 26; g1 &= 0x3ffffff;
    g2 = h2 + c; c = g2 >> 26; g2 &= 0x3ffffff;
    g3 = h3 + c; c = g3 >> 26; g3 &= 0x3ffffff;
    g4 = h4 + c - (1 << 26);
    mask = (g4 >> 31) - 1;
    g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask;
    mask = ~mask;
    h0 = (h0 & mask) | g0; h1 = (h1 & mask) | g1; h2 = (h2 & mask) | g2;
    h3 = (h3 & mask) | g3; h4 = (h4 & mask) | g4;
    h0 = h0 | h1 << 26;
    h1 = h1 >> 6 | h2 << 20;
    h2 = h2 >> 12 | h3 << 14;
    h3 = h3 >> 18 | h4 << 8;
    f = (u64)h0 + st->pad[0]; h0 = (u32)f;
    f = (u64)h1 + st->pad[1] + (f >> 32); h1 = (u32)f;
    f = (u64)h2 + st->pad[2] + (f >> 32); h2 = (u32)f;
    f = (u64)h3 + st->pad[3] + (f >> 32); h3 = (u32)f;
    {
        u32 hs[4] = { h0, h1, h2, h3 };
        int i;
        for (i = 0; i < 4; i++) { mac[4 * i] = hs[i]; mac[4 * i + 1] = hs[i] >> 8; mac[4 * i + 2] = hs[i] >> 16; mac[4 * i + 3] = hs[i] >> 24; }
    }
}

static int chachapoly(const u8 key[32], const u8 nonce[12], const u8 *aad, int alen, u8 *p, int n, u8 tag[16], int dec)
{
    u8 block[64], mac[16], lens[16];
    struct poly st;
    int i, k;
    u32 ctr = 1;
    chacha_block(key, 0, nonce, block);
    poly_init(&st, block);
    {                                            /* the header, zero-padded */
        u8 ab[16];
        memset(ab, 0, 16);
        memcpy(ab, aad, alen);
        poly_blocks(&st, ab, 16);
    }
    if (dec) {
        poly_blocks(&st, p, n & ~15);
        if (n & 15) { u8 last[16]; memset(last, 0, 16); memcpy(last, p + (n & ~15), n & 15); poly_blocks(&st, last, 16); }
    }
    for (i = 0; i < n; i += 64) {
        chacha_block(key, ctr++, nonce, block);
        for (k = 0; k < 64 && i + k < n; k++) p[i + k] ^= block[k];
    }
    if (!dec) {
        poly_blocks(&st, p, n & ~15);
        if (n & 15) { u8 last[16]; memset(last, 0, 16); memcpy(last, p + (n & ~15), n & 15); poly_blocks(&st, last, 16); }
    }
    memset(lens, 0, 16);
    for (i = 0; i < 4; i++) { lens[i] = (u32)alen >> (8 * i); lens[8 + i] = (u32)n >> (8 * i); }
    poly_blocks(&st, lens, 16);
    poly_final(&st, mac);
    if (!dec) { memcpy(tag, mac, 16); return 1; }
    k = 0;
    for (i = 0; i < 16; i++) k |= mac[i] ^ tag[i];
    return k == 0;
}

/* ============================================================
 * TLS 1.3
 * ============================================================ */
#define TLS_AES128 0x1301
#define TLS_CHACHA 0x1303
#define REC_MAX (16384 + 512)

static struct {
    int suite, keylen;
    u8 ckey[32], civ[12], skey[32], siv[12];
    u64 cseq, sseq;
    u8 in[REC_MAX + 16];                  /* a record, as it came */
    int inlen;
    u8 raw[4096];                         /* TCP, not yet a whole record */
    int rawpos, rawlen;
    struct sha256 transcript;
} T;

static int tcp_read_exact(u8 *p, int n)
{
    while (n > 0) {
        int k;
        if (T.rawpos == T.rawlen) {
            k = tcp_recv(T.raw, sizeof T.raw, 15000);
            if (k <= 0) return 0;
            T.rawpos = 0;
            T.rawlen = k;
        }
        k = T.rawlen - T.rawpos;
        if (k > n) k = n;
        memcpy(p, T.raw + T.rawpos, k);
        T.rawpos += k;
        p += k;
        n -= k;
    }
    return 1;
}

static void nonce_of(const u8 iv[12], u64 seq, u8 out[12])
{
    int i;
    memcpy(out, iv, 12);
    for (i = 0; i < 8; i++) out[11 - i] ^= (u8)(seq >> (8 * i));
}

static int seal(int suite, const u8 *key, const u8 nonce[12], const u8 *aad, u8 *p, int n, u8 *tag, int dec)
{
    return suite == TLS_AES128 ? gcm(key, nonce, aad, 5, p, n, tag, dec) : chachapoly(key, nonce, aad, 5, p, n, tag, dec);
}

/* one record -> *type, its plaintext at *data (in T.in), its length;
 * encrypted ones decrypted (the inner type). -1 on an error. */
static int read_record(int *type, u8 **data)
{
    int len;
    if (!tcp_read_exact(T.in, 5)) { tls_error = "The connection was closed."; return -1; }
    len = T.in[3] << 8 | T.in[4];
    if (len > REC_MAX) { tls_error = "A record too long."; return -1; }
    if (!tcp_read_exact(T.in + 5, len)) { tls_error = "The connection was closed."; return -1; }
    *type = T.in[0];
    *data = T.in + 5;
    if (*type == 23 && T.keylen) {
        u8 nonce[12];
        if (len < 17) { tls_error = "A record too short."; return -1; }
        nonce_of(T.siv, T.sseq++, nonce);
        if (!seal(T.suite, T.skey, nonce, T.in, T.in + 5, len - 16, T.in + 5 + len - 16, 1)) {
            tls_error = "A record didn't decrypt (bad tag).";
            return -1;
        }
        len -= 16;
        while (len > 0 && T.in[5 + len - 1] == 0) len--;       /* padding */
        if (len == 0) { tls_error = "An empty record."; return -1; }
        *type = T.in[5 + len - 1];
        len--;
    }
    return len;
}

static u8 outrec[REC_MAX + 64];
static int send_record(int type, const u8 *p, int n)
{
    int len = n;
    outrec[0] = T.keylen ? 23 : type;
    outrec[1] = 3; outrec[2] = T.keylen ? 3 : 1;
    memcpy(outrec + 5, p, n);
    if (T.keylen) {
        u8 nonce[12];
        outrec[5 + n] = type;
        len = n + 1 + 16;
        outrec[3] = len >> 8; outrec[4] = len;
        nonce_of(T.civ, T.cseq++, nonce);
        seal(T.suite, T.ckey, nonce, outrec, outrec + 5, n + 1, outrec + 5 + n + 1, 0);
    } else {
        outrec[3] = len >> 8; outrec[4] = len;
    }
    return tcp_send(outrec, 5 + len) == 5 + len;
}

static void keys_from(const u8 csec[32], const u8 ssec[32])
{
    expand_label(csec, "key", 0, 0, T.ckey, T.keylen);
    expand_label(csec, "iv", 0, 0, T.civ, 12);
    expand_label(ssec, "key", 0, 0, T.skey, T.keylen);
    expand_label(ssec, "iv", 0, 0, T.siv, 12);
    T.cseq = T.sseq = 0;
}

static void transcript_hash(u8 out[32])
{
    struct sha256 copy = T.transcript;
    sha_final(&copy, out);
}

static void random_bytes(u8 *p, int n)
{
    static u32 counter;
    struct sha256 s;
    u8 h[32];
    while (n > 0) {
        u32 lo, hi, t = millis();
        int k;
        __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
        sha_init(&s);
        sha_update(&s, &lo, 4); sha_update(&s, &hi, 4); sha_update(&s, &t, 4);
        counter++;
        sha_update(&s, &counter, 4);
        sha_update(&s, &p, 4);
        sha_final(&s, h);
        k = n < 32 ? n : 32;
        memcpy(p, h, k);
        p += k;
        n -= k;
    }
}

static u8 hsbuf[65536];                   /* handshake messages, gathered */

/* The handshake, then the request and the answer. */
static int tls_get(const char *host, int port, const char *path, char *out, int max)
{
    u8 priv[32], pub[32], shared[32], zero[32], early[32], derived[32], hs[32], master[32];
    u8 chs[32], shs[32], cap[32], sap[32], h[32];
    u8 ch[512];
    int n = 0, hl = strlen(host), hsn = 0, got_finished = 0, total = 0, i;
    static const u8 base9[32] = { 9 };

    T.keylen = 0;
    T.rawpos = T.rawlen = 0;
    sha_init(&T.transcript);
    random_bytes(priv, 32);
    x25519(pub, priv, base9);

    /* ClientHello */
    ch[n++] = 1; n += 3;                            /* type, length (later) */
    ch[n++] = 3; ch[n++] = 3;                       /* legacy version 1.2 */
    random_bytes(ch + n, 32); n += 32;
    ch[n++] = 32; random_bytes(ch + n, 32); n += 32; /* a session id (middleboxes) */
    ch[n++] = 0; ch[n++] = 4;                       /* the ciphers */
    ch[n++] = 0x13; ch[n++] = 0x01; ch[n++] = 0x13; ch[n++] = 0x03;
    ch[n++] = 1; ch[n++] = 0;                       /* no compression */
    {
        int ext = n, e;
        n += 2;
        /* server_name */
        ch[n++] = 0; ch[n++] = 0; ch[n++] = 0; ch[n++] = hl + 5;
        ch[n++] = 0; ch[n++] = hl + 3; ch[n++] = 0; ch[n++] = 0; ch[n++] = hl;
        memcpy(ch + n, host, hl); n += hl;
        /* supported_versions: TLS 1.3 */
        ch[n++] = 0; ch[n++] = 0x2b; ch[n++] = 0; ch[n++] = 3; ch[n++] = 2; ch[n++] = 3; ch[n++] = 4;
        /* supported_groups: x25519 */
        ch[n++] = 0; ch[n++] = 0x0a; ch[n++] = 0; ch[n++] = 4; ch[n++] = 0; ch[n++] = 2; ch[n++] = 0; ch[n++] = 0x1d;
        /* signature_algorithms */
        {
            static const u8 sigs[] = { 0x04, 0x03, 0x08, 0x04, 0x04, 0x01, 0x05, 0x03, 0x08, 0x05,
                                       0x05, 0x01, 0x08, 0x06, 0x06, 0x01, 0x08, 0x07 };
            ch[n++] = 0; ch[n++] = 0x0d; ch[n++] = 0; ch[n++] = sizeof sigs + 2;
            ch[n++] = 0; ch[n++] = sizeof sigs;
            memcpy(ch + n, sigs, sizeof sigs); n += sizeof sigs;
        }
        /* key_share: our x25519 key */
        ch[n++] = 0; ch[n++] = 0x33; ch[n++] = 0; ch[n++] = 38; ch[n++] = 0; ch[n++] = 36;
        ch[n++] = 0; ch[n++] = 0x1d; ch[n++] = 0; ch[n++] = 32;
        memcpy(ch + n, pub, 32); n += 32;
        e = n - ext - 2;
        ch[ext] = e >> 8; ch[ext + 1] = e;
    }
    ch[1] = 0; ch[2] = (n - 4) >> 8; ch[3] = n - 4;

    if (tcp_open(host, port) < 0) { tls_error = "Can't connect to the server (or find its name)."; return -1; }
    sha_update(&T.transcript, ch, n);
    if (!send_record(22, ch, n)) { tls_error = "Can't send."; goto fail; }

    /* ServerHello */
    for (;;) {
        int type, len, p, end, server_ok = 0, have_key = 0;
        u8 *d, spub[32];
        len = read_record(&type, &d);
        if (len < 0) goto fail;
        if (type == 21) { tls_error = "The server refused the connection (an alert) - it may not speak TLS 1.3."; goto fail; }
        if (type != 22) continue;
        if (len < 4 || d[0] != 2) { tls_error = "Not a ServerHello."; goto fail; }
        sha_update(&T.transcript, d, len);
        {
            static const u8 hrr[8] = { 0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11 };
            if (!memcmp(d + 6, hrr, 8)) { tls_error = "The server wants a key exchange LexOS doesn't have."; goto fail; }
        }
        p = 4 + 2 + 32;
        p += 1 + d[p];                                  /* session id */
        T.suite = d[p] << 8 | d[p + 1];
        p += 3;
        end = p + 2 + (d[p] << 8 | d[p + 1]);
        p += 2;
        while (p + 4 <= end && p + 4 <= len) {
            int et = d[p] << 8 | d[p + 1], el = d[p + 2] << 8 | d[p + 3];
            p += 4;
            if (et == 0x2b && el == 2 && d[p] == 3 && d[p + 1] == 4) server_ok = 1;
            if (et == 0x33 && el >= 36 && (d[p] << 8 | d[p + 1]) == 0x1d) { memcpy(spub, d + p + 4, 32); have_key = 1; }
            p += el;
        }
        if (!server_ok) { tls_error = "The server doesn't speak TLS 1.3."; goto fail; }
        if (!have_key) { tls_error = "No key from the server."; goto fail; }
        if (T.suite != TLS_AES128 && T.suite != TLS_CHACHA) { tls_error = "A cipher LexOS doesn't have."; goto fail; }
        x25519(shared, priv, spub);
        break;
    }

    /* the handshake's keys */
    memset(zero, 0, 32);
    hmac(zero, 32, zero, 32, early);                    /* early secret */
    {
        struct sha256 s;
        u8 empty[32];
        sha_init(&s);
        sha_final(&s, empty);
        expand_label(early, "derived", empty, 32, derived, 32);
        hmac(derived, 32, shared, 32, hs);
        transcript_hash(h);
        expand_label(hs, "c hs traffic", h, 32, chs, 32);
        expand_label(hs, "s hs traffic", h, 32, shs, 32);
        expand_label(hs, "derived", empty, 32, derived, 32);
        hmac(derived, 32, zero, 32, master);
    }
    T.keylen = T.suite == TLS_AES128 ? 16 : 32;
    keys_from(chs, shs);

    /* EncryptedExtensions, Certificate, CertificateVerify, Finished */
    while (!got_finished) {
        int type, len, p = 0;
        u8 *d;
        len = read_record(&type, &d);
        if (len < 0) goto fail;
        if (type == 20) continue;                       /* ChangeCipherSpec: nothing */
        if (type == 21) { tls_error = "The server sent an alert."; goto fail; }
        if (type != 22) { tls_error = "Something else than the handshake."; goto fail; }
        if (hsn + len > (int)sizeof hsbuf) { tls_error = "The handshake's too big."; goto fail; }
        memcpy(hsbuf + hsn, d, len);
        hsn += len;
        while (hsn - p >= 4) {
            int mt = hsbuf[p], ml = hsbuf[p + 1] << 16 | hsbuf[p + 2] << 8 | hsbuf[p + 3];
            if (hsn - p < 4 + ml) break;
            if (mt == 20) {                             /* Finished: checked */
                u8 fkey[32], want[32];
                transcript_hash(h);
                expand_label(shs, "finished", 0, 0, fkey, 32);
                hmac(fkey, 32, h, 32, want);
                if (ml != 32 || memcmp(want, hsbuf + p + 4, 32)) { tls_error = "The server's Finished is wrong."; goto fail; }
                got_finished = 1;
            }
            sha_update(&T.transcript, hsbuf + p, 4 + ml);
            p += 4 + ml;
            if (got_finished) break;
        }
        memmove(hsbuf, hsbuf + p, hsn - p);
        hsn -= p;
    }

    /* the application's keys; our Finished */
    transcript_hash(h);
    expand_label(master, "c ap traffic", h, 32, cap, 32);
    expand_label(master, "s ap traffic", h, 32, sap, 32);
    {
        u8 fkey[32], fin[36];
        static const u8 ccs[6] = { 20, 3, 3, 0, 1, 1 };
        tcp_send(ccs, 6);
        expand_label(chs, "finished", 0, 0, fkey, 32);
        fin[0] = 20; fin[1] = 0; fin[2] = 0; fin[3] = 32;
        hmac(fkey, 32, h, 32, fin + 4);
        if (!send_record(22, fin, 36)) { tls_error = "Can't send."; goto fail; }
    }
    keys_from(cap, sap);

    /* the request, and the answer */
    {
        char req[600];
        req[0] = 0;
        strcpy(req, "GET ");
        strcpy(req + strlen(req), path);
        strcpy(req + strlen(req), " HTTP/1.1\r\nHost: ");
        strcpy(req + strlen(req), host);
        strcpy(req + strlen(req), "\r\nUser-Agent: LexOS-Web/1.0\r\nAccept: text/html, */*\r\nConnection: close\r\n\r\n");
        if (!send_record(23, (const u8 *)req, strlen(req))) { tls_error = "Can't send."; goto fail; }
    }
    for (;;) {
        int type, len;
        u8 *d;
        len = read_record(&type, &d);
        if (len < 0) {
            if (total > 0) break;                       /* (closed without close_notify) */
            goto fail;
        }
        if (type == 21) break;                          /* close_notify */
        if (type != 23) continue;                       /* tickets and such */
        for (i = 0; i < len && total < max; i++) out[total++] = d[i];
    }
    tcp_close();
    return total;
fail:
    tcp_close();
    return -1;
}

#endif
