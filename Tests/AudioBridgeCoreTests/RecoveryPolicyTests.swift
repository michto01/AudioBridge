import AudioBridgeCore
import XCTest

/// Source only; no login registration, HAL, plugin or real timers.
final class RecoveryPolicyTests: XCTestCase {
    func testLaunchResumeRequiresExplicitPreferenceAndNonStoppedIntent() {
        XCTAssertFalse(RecoveryPolicy.shouldResume(autoResume: false, desired: false))
        XCTAssertFalse(RecoveryPolicy.shouldResume(autoResume: false, desired: true))
        XCTAssertFalse(RecoveryPolicy.shouldResume(autoResume: true, desired: false))
        XCTAssertTrue(RecoveryPolicy.shouldResume(autoResume: true, desired: true))
    }
    func testDefaultStopAndCappedIndefiniteBackoff() {
        var policy = RecoveryPolicy()
        XCTAssertFalse(policy.desired)
        policy.start()
        var now = 0.0
        for delay in [1.0, 2, 4, 8, 16, 30, 30, 30] {
            policy.attempting(now: now)
            policy.failed(.recoverable, now: now)
            XCTAssertEqual(policy.retryAt, now + delay)
            XCTAssertFalse(policy.due(now: now + delay - 0.01))
            XCTAssertTrue(policy.due(now: now + delay))
            now += delay
        }
        policy.stop()
        policy.failed(.recoverable, now: now)
        policy.deviceChanged(now: now)
        XCTAssertNil(policy.retryAt)
        XCTAssertFalse(policy.due(now: now + 10000))
    }
    func testPermissionConfigurationAndUnsafeTeardownDoNotRetry() {
        for kind in [BridgeFailureKind.actionRequired, .unsafeTeardown] {
            var policy = RecoveryPolicy(); policy.start()
            policy.failed(kind, now: 10)
            XCTAssertTrue(policy.desired) // Observed failure is not a manual Stop.
            XCTAssertTrue(policy.blocked)
            policy.deviceChanged(now: 20)
            XCTAssertNil(policy.retryAt)
            policy.start() // Explicit operator action clears the block.
            XCTAssertFalse(policy.blocked)
        }
    }
    func testReconnectCanAccelerateButNotStormAndHealthyResetIsDelayed() {
        var policy = RecoveryPolicy(); policy.start()
        for _ in 0..<6 { policy.attempting(now: 10); policy.failed(.recoverable, now: 10) }
        XCTAssertEqual(policy.retryAt, 40)
        policy.deviceChanged(now: 10.1)
        XCTAssertEqual(policy.retryAt, 11)
        XCTAssertFalse(policy.due(now: 10.9))
        policy.healthy(seconds: 19.9)
        XCTAssertEqual(policy.attempts, 6)
        policy.healthy(seconds: 20)
        XCTAssertEqual(policy.attempts, 0)
    }
}
