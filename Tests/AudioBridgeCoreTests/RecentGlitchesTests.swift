import AudioBridgeCore
import XCTest

/// Deterministic source only; no clock wait or audio execution.
final class RecentGlitchesTests: XCTestCase {
    func testStartupIsNotAGlitchAndCleanStartCanRunImmediately() {
        var tracker = RecentGlitches()
        tracker.update(now: 0, healthy: false, counters: .init())
        XCTAssertFalse(tracker.active)
        tracker.update(now: 1, healthy: true, counters: .init())
        XCTAssertFalse(tracker.active)
    }
    func testHistoricalGlitchClearsAtFiveHealthySecondsWithoutResettingCounts() {
        var tracker = RecentGlitches()
        let counts = DeliveryCounters(underruns: 386, rebuffers: 3)
        tracker.update(now: 10, healthy: true, counters: counts)
        XCTAssertTrue(tracker.active)
        tracker.update(now: 14.99, healthy: true, counters: counts)
        XCTAssertTrue(tracker.active)
        tracker.update(now: 15, healthy: true, counters: counts)
        XCTAssertFalse(tracker.active)
        tracker.update(now: 16, healthy: true, counters: counts)
        XCTAssertFalse(tracker.active)
        XCTAssertEqual(counts.underruns, 386)
    }
    func testNewGlitchAndCallbackGapRestartTheHealthyWindow() {
        var tracker = RecentGlitches()
        var counts = DeliveryCounters(underruns: 1)
        tracker.update(now: 0, healthy: true, counters: counts)
        tracker.update(now: 4, healthy: true, counters: counts)
        counts = DeliveryCounters(underruns: 2)
        tracker.update(now: 4.5, healthy: true, counters: counts)
        XCTAssertEqual(tracker.cleanSeconds, 0)
        tracker.update(now: 10, healthy: false, counters: counts)
        tracker.update(now: 11, healthy: true, counters: counts)
        tracker.update(now: 15.99, healthy: true, counters: counts)
        XCTAssertTrue(tracker.active)
        tracker.update(now: 16, healthy: true, counters: counts)
        XCTAssertFalse(tracker.active)
    }
    func testRecenteringDiscardsAndUnhealthyDeliveryAreReported() {
        var tracker = RecentGlitches()
        tracker.update(now: 0, healthy: true, counters: .init())
        tracker.update(now: 1, healthy: false, counters: .init())
        XCTAssertTrue(tracker.active)
        tracker.update(now: 100, healthy: false, counters: .init())
        XCTAssertEqual(tracker.cleanSeconds, 0)
        tracker.update(now: 101, healthy: true, counters: .init(recentered: 10))
        tracker.update(now: 106, healthy: true, counters: .init(recentered: 10))
        XCTAssertFalse(tracker.active)
        tracker.update(now: 107, healthy: true, counters: .init(recentered: 11))
        XCTAssertTrue(tracker.active)
        tracker.update(now: 123, healthy: true, counters: .init(underruns: 1, recentered: 11))
        XCTAssertTrue(tracker.active)
    }
}
