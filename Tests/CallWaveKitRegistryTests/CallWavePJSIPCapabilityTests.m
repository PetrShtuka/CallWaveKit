#import <XCTest/XCTest.h>

#import "CallWaveClient.h"

#if __has_include(<PJSIP/pjsua.h>)
#import <PJSIP/pjsua.h>
#else
#import <pjsua.h>
#endif

// Capability probes for the vendored XCFramework: the SHA-256 digest patch and
// the Opus codec only exist in binaries produced by the patched build script,
// so these tests fail against an older binary release.
@interface CallWavePJSIPCapabilityTests : XCTestCase
@end

@implementation CallWavePJSIPCapabilityTests

- (void)testSHA256DigestMatchesKnownAnswer {
    // RFC 7616-style digest with known inputs; the expected value is computed
    // independently (ha1 = H(user:realm:pass), ha2 = H(method:uri),
    // response = H(ha1:nonce:ha2)).
    XCTAssertEqual(pj_init(), PJ_SUCCESS);

    pj_caching_pool cachingPool;
    pj_caching_pool_init(&cachingPool, NULL, 0);
    pj_pool_t *pool = pj_pool_create(&cachingPool.factory, "kat", 1024, 1024, NULL);

    pjsip_cred_info credential;
    pj_bzero(&credential, sizeof(credential));
    credential.realm = pj_str("atlanta.com");
    credential.scheme = pj_str("digest");
    credential.username = pj_str("alice");
    credential.data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    credential.data = pj_str("secret");

    pj_str_t result;
    result.ptr = (char *)pj_pool_alloc(pool, PJSIP_SHA256STRLEN);
    result.slen = PJSIP_SHA256STRLEN;

    pj_str_t nonce = pj_str("xyz123");
    pj_str_t uri = pj_str("sip:atlanta.com");
    pj_str_t method = pj_str("REGISTER");

    pj_status_t status = pjsip_auth_create_digestSHA256(
        &result, &nonce, NULL, NULL, NULL, &uri, &credential.realm,
        &credential, &method);
    XCTAssertEqual(status, PJ_SUCCESS);

    NSString *digest = [[NSString alloc] initWithBytes:result.ptr
                                                length:(NSUInteger)result.slen
                                              encoding:NSASCIIStringEncoding];
    XCTAssertEqualObjects(
        digest,
        @"162cb9c512c0a6d4e6e51d3e2cebafcb87450966f10c51468a5f2f28235adabb");

    // MD5 must keep working alongside SHA-256.
    pj_str_t md5Result;
    md5Result.ptr = (char *)pj_pool_alloc(pool, PJSIP_MD5STRLEN);
    md5Result.slen = PJSIP_MD5STRLEN;
    status = pjsip_auth_create_digest(
        &md5Result, &nonce, NULL, NULL, NULL, &uri, &credential.realm,
        &credential, &method);
    XCTAssertEqual(status, PJ_SUCCESS);
    XCTAssertEqual(md5Result.slen, PJSIP_MD5STRLEN);

    pj_pool_release(pool);
    pj_caching_pool_destroy(&cachingPool);
}

- (void)testOpusCodecIsRegistered {
    CallWaveConfiguration *configuration =
        [[CallWaveConfiguration alloc] initWithBuilder:^(CallWaveConfigurationBuilder *builder) {
            builder.host = @"opus.invalid";
            builder.username = @"opus-probe";
            builder.password = @"not-a-real-credential";
        }];
    CallWaveClient *client =
        [[CallWaveClient alloc] initWithConfiguration:configuration
                                              options:CallWaveIntegrationOptionNone
                                             provider:nil
                                  engineConfiguration:nil];
    NSError *error = nil;
    XCTAssertTrue([client startEngineWithError:&error], @"%@", error);
    // Opus registers with the codec manager during pjsua_init; an old binary
    // without --with-opus answers PJ_ENOTFOUND here.
    pj_str_t opusId = pj_str("opus/48000/2");
    pj_status_t opusStatus = pjsua_codec_set_priority(&opusId, 250);
    XCTAssertEqual(opusStatus, PJ_SUCCESS);
    pj_str_t pcmaId = pj_str("PCMA/8000/1");
    pj_status_t pcmaStatus = pjsua_codec_set_priority(&pcmaId, 200);
    XCTAssertEqual(pcmaStatus, PJ_SUCCESS);
    [client stop];
}

@end
