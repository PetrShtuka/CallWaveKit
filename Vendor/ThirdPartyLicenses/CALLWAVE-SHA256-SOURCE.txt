/*
 * Minimal SHA-256 (FIPS 180-4) for the CallWaveKit PJSIP build.
 *
 * PJSIP's digest-authentication code only knows MD5 when it is built without
 * OpenSSL, which is the case for the Apple-TLS (`PJ_SSL_SOCK_IMP_APPLE`)
 * XCFramework. This header provides the SHA-256 half of the small EVP-shaped
 * shim that Patches/sip-auth-client-sha256.patch installs into
 * sip_auth_client.c. It is written to the public-domain reference algorithm
 * description and carries no third-party code.
 *
 * The header is self-contained and defines only static functions, so it can be
 * included from exactly one translation unit without build-system changes.
 */

#ifndef CALLWAVE_SHA256_H
#define CALLWAVE_SHA256_H

#include <string.h>

typedef unsigned char cw_sha256_byte;
typedef unsigned int cw_sha256_word;

typedef struct cw_sha256_ctx {
    cw_sha256_byte data[64];
    cw_sha256_word data_len;
    unsigned long long bit_len;
    cw_sha256_word state[8];
} cw_sha256_ctx;

static const cw_sha256_word cw_sha256_k[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
};

static cw_sha256_word cw_sha256_rotr(cw_sha256_word value, cw_sha256_word bits) {
    return (value >> bits) | (value << (32u - bits));
}

static void cw_sha256_transform(cw_sha256_ctx *ctx, const cw_sha256_byte *data) {
    cw_sha256_word a, b, c, d, e, f, g, h;
    cw_sha256_word m[64];
    cw_sha256_word i, j;

    for (i = 0, j = 0; i < 16; ++i, j += 4) {
        m[i] = ((cw_sha256_word)data[j] << 24) |
               ((cw_sha256_word)data[j + 1] << 16) |
               ((cw_sha256_word)data[j + 2] << 8) |
               ((cw_sha256_word)data[j + 3]);
    }
    for (; i < 64; ++i) {
        cw_sha256_word s0 = cw_sha256_rotr(m[i - 15], 7) ^
                            cw_sha256_rotr(m[i - 15], 18) ^ (m[i - 15] >> 3);
        cw_sha256_word s1 = cw_sha256_rotr(m[i - 2], 17) ^
                            cw_sha256_rotr(m[i - 2], 19) ^ (m[i - 2] >> 10);
        m[i] = m[i - 16] + s0 + m[i - 7] + s1;
    }

    a = ctx->state[0];
    b = ctx->state[1];
    c = ctx->state[2];
    d = ctx->state[3];
    e = ctx->state[4];
    f = ctx->state[5];
    g = ctx->state[6];
    h = ctx->state[7];

    for (i = 0; i < 64; ++i) {
        cw_sha256_word s1 = cw_sha256_rotr(e, 6) ^ cw_sha256_rotr(e, 11) ^
                            cw_sha256_rotr(e, 25);
        cw_sha256_word ch = (e & f) ^ (~e & g);
        cw_sha256_word temp1 = h + s1 + ch + cw_sha256_k[i] + m[i];
        cw_sha256_word s0 = cw_sha256_rotr(a, 2) ^ cw_sha256_rotr(a, 13) ^
                            cw_sha256_rotr(a, 22);
        cw_sha256_word maj = (a & b) ^ (a & c) ^ (b & c);
        cw_sha256_word temp2 = s0 + maj;

        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }

    ctx->state[0] += a;
    ctx->state[1] += b;
    ctx->state[2] += c;
    ctx->state[3] += d;
    ctx->state[4] += e;
    ctx->state[5] += f;
    ctx->state[6] += g;
    ctx->state[7] += h;
}

static __attribute__((noinline)) void cw_sha256_init(cw_sha256_ctx *ctx) {
    ctx->data_len = 0;
    ctx->bit_len = 0;
    ctx->state[0] = 0x6a09e667u;
    ctx->state[1] = 0xbb67ae85u;
    ctx->state[2] = 0x3c6ef372u;
    ctx->state[3] = 0xa54ff53au;
    ctx->state[4] = 0x510e527fu;
    ctx->state[5] = 0x9b05688cu;
    ctx->state[6] = 0x1f83d9abu;
    ctx->state[7] = 0x5be0cd19u;
}

static void cw_sha256_update(cw_sha256_ctx *ctx, const cw_sha256_byte *data,
                             unsigned len) {
    unsigned i;
    for (i = 0; i < len; ++i) {
        ctx->data[ctx->data_len] = data[i];
        ctx->data_len++;
        if (ctx->data_len == 64) {
            cw_sha256_transform(ctx, ctx->data);
            ctx->bit_len += 512;
            ctx->data_len = 0;
        }
    }
}

static void cw_sha256_final(cw_sha256_ctx *ctx, cw_sha256_byte *digest) {
    cw_sha256_word i = ctx->data_len;

    if (ctx->data_len < 56) {
        ctx->data[i++] = 0x80;
        while (i < 56) {
            ctx->data[i++] = 0x00;
        }
    } else {
        ctx->data[i++] = 0x80;
        while (i < 64) {
            ctx->data[i++] = 0x00;
        }
        cw_sha256_transform(ctx, ctx->data);
        memset(ctx->data, 0, 56);
    }

    ctx->bit_len += (unsigned long long)ctx->data_len * 8ull;
    ctx->data[63] = (cw_sha256_byte)(ctx->bit_len);
    ctx->data[62] = (cw_sha256_byte)(ctx->bit_len >> 8);
    ctx->data[61] = (cw_sha256_byte)(ctx->bit_len >> 16);
    ctx->data[60] = (cw_sha256_byte)(ctx->bit_len >> 24);
    ctx->data[59] = (cw_sha256_byte)(ctx->bit_len >> 32);
    ctx->data[58] = (cw_sha256_byte)(ctx->bit_len >> 40);
    ctx->data[57] = (cw_sha256_byte)(ctx->bit_len >> 48);
    ctx->data[56] = (cw_sha256_byte)(ctx->bit_len >> 56);
    cw_sha256_transform(ctx, ctx->data);

    for (i = 0; i < 4; ++i) {
        unsigned shift = (3u - i) * 8u;
        digest[i]      = (cw_sha256_byte)((ctx->state[0] >> shift) & 0xffu);
        digest[i + 4]  = (cw_sha256_byte)((ctx->state[1] >> shift) & 0xffu);
        digest[i + 8]  = (cw_sha256_byte)((ctx->state[2] >> shift) & 0xffu);
        digest[i + 12] = (cw_sha256_byte)((ctx->state[3] >> shift) & 0xffu);
        digest[i + 16] = (cw_sha256_byte)((ctx->state[4] >> shift) & 0xffu);
        digest[i + 20] = (cw_sha256_byte)((ctx->state[5] >> shift) & 0xffu);
        digest[i + 24] = (cw_sha256_byte)((ctx->state[6] >> shift) & 0xffu);
        digest[i + 28] = (cw_sha256_byte)((ctx->state[7] >> shift) & 0xffu);
    }
}

#endif /* CALLWAVE_SHA256_H */
