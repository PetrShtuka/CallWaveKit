#import <XCTest/XCTest.h>

#import "CallWaveClient.h"

#if __has_include(<PJSIP/pjsua.h>)
#import <PJSIP/pjsua.h>
#else
#import <pjsua.h>
#endif

// The session-timer mapping is a private client method; it is declared here so
// the tests can drive it without a registrar, mirroring the other reliability
// suites.
@interface CallWaveClient (SessionTimersTests)
- (void)configureSessionTimersForAccount:(pjsua_acc_config *)account
                           configuration:(CallWaveConfiguration *)configuration;
@end

@interface CallWaveSessionTimersTests : XCTestCase
@end

@implementation CallWaveSessionTimersTests

- (CallWaveConfiguration *)configurationWithMode:(CallWaveSessionTimersMode)mode {
    return [[CallWaveConfiguration alloc] initWithBuilder:^(CallWaveConfigurationBuilder *builder) {
        builder.host = @"sip.example.com";
        builder.username = @"1001";
        builder.password = @"not-a-real-credential";
        builder.sessionTimersMode = mode;
    }];
}

- (CallWaveClient *)makeClient {
    return [[CallWaveClient alloc] initWithConfiguration:nil
                                                 options:CallWaveIntegrationOptionNone
                                                provider:nil
                                     engineConfiguration:nil];
}

- (void)testDefaultModeOffersTimersWithoutRequiringThem {
    CallWaveConfiguration *configuration =
        [[CallWaveConfiguration alloc] initWithBuilder:^(CallWaveConfigurationBuilder *builder) {
            builder.host = @"sip.example.com";
            builder.username = @"1001";
            builder.password = @"not-a-real-credential";
        }];
    pjsua_acc_config account;
    pj_bzero(&account, sizeof(account));

    [[self makeClient] configureSessionTimersForAccount:&account configuration:configuration];

    XCTAssertEqual(account.use_timer, PJSUA_SIP_TIMER_OPTIONAL);
    XCTAssertEqual(account.timer_setting.sess_expires, 1800);
    XCTAssertEqual(account.timer_setting.min_se, 90);
}

- (void)testInactiveModeDisablesTimers {
    pjsua_acc_config account;
    pj_bzero(&account, sizeof(account));
    // Prove the method overwrites a stale value instead of leaving it.
    account.use_timer = PJSUA_SIP_TIMER_ALWAYS;

    [[self makeClient] configureSessionTimersForAccount:&account
                                          configuration:[self configurationWithMode:CallWaveSessionTimersModeInactive]];

    XCTAssertEqual(account.use_timer, PJSUA_SIP_TIMER_INACTIVE);
}

- (void)testAlwaysModeOffersTimersOnEveryCall {
    pjsua_acc_config account;
    pj_bzero(&account, sizeof(account));

    [[self makeClient] configureSessionTimersForAccount:&account
                                          configuration:[self configurationWithMode:CallWaveSessionTimersModeAlways]];

    XCTAssertEqual(account.use_timer, PJSUA_SIP_TIMER_ALWAYS);
}

- (void)testRequiredModeRejectsPeersWithoutTimers {
    pjsua_acc_config account;
    pj_bzero(&account, sizeof(account));

    [[self makeClient] configureSessionTimersForAccount:&account
                                          configuration:[self configurationWithMode:CallWaveSessionTimersModeRequired]];

    XCTAssertEqual(account.use_timer, PJSUA_SIP_TIMER_REQUIRED);
}

- (void)testCustomIntervalsReachTheAccount {
    CallWaveConfiguration *configuration =
        [[CallWaveConfiguration alloc] initWithBuilder:^(CallWaveConfigurationBuilder *builder) {
            builder.host = @"sip.example.com";
            builder.username = @"1001";
            builder.password = @"not-a-real-credential";
            builder.sessionTimerInterval = 600;
            builder.sessionTimerMinimum = 120;
        }];
    pjsua_acc_config account;
    pj_bzero(&account, sizeof(account));

    [[self makeClient] configureSessionTimersForAccount:&account configuration:configuration];

    XCTAssertEqual(account.timer_setting.sess_expires, 600);
    XCTAssertEqual(account.timer_setting.min_se, 120);
}

- (void)testNormalizedIntervalsFitThePJSIPAccountFields {
    CallWaveConfiguration *configuration =
        [[CallWaveConfiguration alloc] initWithBuilder:^(CallWaveConfigurationBuilder *builder) {
            builder.host = @"sip.example.com";
            builder.username = @"1001";
            builder.password = @"not-a-real-credential";
            builder.sessionTimerInterval = NSUIntegerMax;
            builder.sessionTimerMinimum = NSUIntegerMax;
        }];
    pjsua_acc_config account;
    pj_bzero(&account, sizeof(account));

    [[self makeClient] configureSessionTimersForAccount:&account configuration:configuration];

    XCTAssertEqual(account.timer_setting.sess_expires, UINT_MAX);
    XCTAssertEqual(account.timer_setting.min_se, UINT_MAX);
}

@end
