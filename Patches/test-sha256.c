#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "callwave-sha256.h"

static int check(const char *label, const unsigned char *data, unsigned len,
                 const char *expected_hex) {
    cw_sha256_ctx ctx;
    unsigned char digest[32];
    char hex[65];
    int i;
    cw_sha256_init(&ctx);
    cw_sha256_update(&ctx, data, len);
    cw_sha256_final(&ctx, digest);
    for (i = 0; i < 32; i++) {
        sprintf(hex + i * 2, "%02x", digest[i]);
    }
    hex[64] = 0;
    if (strcmp(hex, expected_hex) != 0) {
        printf("FAIL %s: got %s want %s\n", label, hex, expected_hex);
        return 1;
    }
    printf("OK   %s\n", label);
    return 0;
}

int main(void) {
    int failures = 0;
    failures += check("empty", (const unsigned char *)"", 0,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    failures += check("abc", (const unsigned char *)"abc", 3,
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    failures += check("448-bit", (const unsigned char *)
        "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56,
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");

    /* 1,000,000 x 'a', fed in odd-sized chunks to exercise buffering. */
    {
        unsigned char *block = malloc(7919);
        cw_sha256_ctx ctx;
        unsigned char digest[32];
        char hex[65];
        int remaining = 1000000;
        int i;
        memset(block, 'a', 7919);
        cw_sha256_init(&ctx);
        while (remaining > 0) {
            int chunk = remaining < 7919 ? remaining : 7919;
            cw_sha256_update(&ctx, block, (unsigned)chunk);
            remaining -= chunk;
        }
        cw_sha256_final(&ctx, digest);
        for (i = 0; i < 32; i++) {
            sprintf(hex + i * 2, "%02x", digest[i]);
        }
        hex[64] = 0;
        if (strcmp(hex,
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0") != 0) {
            printf("FAIL million-a: got %s\n", hex);
            failures++;
        } else {
            printf("OK   million-a\n");
        }
        free(block);
    }
    return failures == 0 ? 0 : 1;
}
