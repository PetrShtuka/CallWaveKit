import XCTest
@testable import CallWaveKit

final class CallWaveEngineQualityConfigurationTests: XCTestCase {

    func testQualityMonitoringDefaults() {
        let configuration = CallWaveEngineConfiguration.defaultConfiguration()
        XCTAssertTrue(configuration.qualityWarningsEnabled)
        XCTAssertEqual(configuration.qualityWarningPacketLossThreshold, 0.05, accuracy: 1e-9)
        XCTAssertEqual(configuration.qualityWarningJitterThreshold, 0.03, accuracy: 1e-9)
        XCTAssertEqual(configuration.qualityWarningRoundTripTimeThreshold, 0.3, accuracy: 1e-9)
        XCTAssertEqual(configuration.noMediaTimeout, 5.0, accuracy: 1e-9)
        XCTAssertFalse(configuration.terminatesCallOnNoMedia)
        XCTAssertTrue(configuration.isQoSTaggingEnabled)
    }

    func testNegativeThresholdsClampToZero() {
        let configuration = CallWaveEngineConfiguration.defaultConfiguration()
        configuration.qualityWarningPacketLossThreshold = -1
        configuration.qualityWarningJitterThreshold = -1
        configuration.qualityWarningRoundTripTimeThreshold = -1
        configuration.noMediaTimeout = -1
        XCTAssertEqual(configuration.qualityWarningPacketLossThreshold, 0)
        XCTAssertEqual(configuration.qualityWarningJitterThreshold, 0)
        XCTAssertEqual(configuration.qualityWarningRoundTripTimeThreshold, 0)
        XCTAssertEqual(configuration.noMediaTimeout, 0)
    }

    func testCopyPreservesQualitySettings() {
        let configuration = CallWaveEngineConfiguration.defaultConfiguration()
        configuration.qualityWarningsEnabled = false
        configuration.qualityWarningPacketLossThreshold = 0.12
        configuration.qualityWarningJitterThreshold = 0.05
        configuration.qualityWarningRoundTripTimeThreshold = 0.8
        configuration.noMediaTimeout = 9
        configuration.terminatesCallOnNoMedia = true
        configuration.isQoSTaggingEnabled = false

        let copy = configuration.copy() as! CallWaveEngineConfiguration
        XCTAssertFalse(copy.qualityWarningsEnabled)
        XCTAssertEqual(copy.qualityWarningPacketLossThreshold, 0.12, accuracy: 1e-9)
        XCTAssertEqual(copy.qualityWarningJitterThreshold, 0.05, accuracy: 1e-9)
        XCTAssertEqual(copy.qualityWarningRoundTripTimeThreshold, 0.8, accuracy: 1e-9)
        XCTAssertEqual(copy.noMediaTimeout, 9, accuracy: 1e-9)
        XCTAssertTrue(copy.terminatesCallOnNoMedia)
        XCTAssertFalse(copy.isQoSTaggingEnabled)
    }
}
