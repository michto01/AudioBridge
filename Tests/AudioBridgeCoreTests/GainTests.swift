import AudioBridgeEngine
import AudioBridgeRealtime
import XCTest

/// Pure DSP tests, written but intentionally not executed in this slice.
final class GainTests: XCTestCase {
    func testDecibelsToAmplitude() {
        XCTAssertEqual(GainSettings.amplitude(decibels: 0), 1)
        XCTAssertEqual(GainSettings.amplitude(decibels: -6), 0.501187, accuracy: 0.000001)
        XCTAssertEqual(GainSettings.amplitude(decibels: -60), 0.001, accuracy: 0.000001)
        XCTAssertEqual(GainSettings.amplitude(decibels: 12), 3.981072, accuracy: 0.000001)
        XCTAssertEqual(GainSettings.amplitude(decibels: .nan), 1)
        XCTAssertEqual(GainSettings.amplitude(decibels: 1000), GainSettings.amplitude(decibels: 12))
        XCTAssertEqual(GainSettings.amplitude(decibels: -1000), GainSettings.amplitude(decibels: -60))
    }
    func testLinearRampReachesExactTarget() {
        var ramp = ABGainRamp(current: 1, target: 1, step: 0, remaining: 0)
        ABGainRetarget(&ramp, 0.25, 4)
        XCTAssertEqual(ABGainNext(&ramp), 0.8125)
        XCTAssertEqual(ABGainNext(&ramp), 0.625)
        XCTAssertEqual(ABGainNext(&ramp), 0.4375)
        XCTAssertEqual(ABGainNext(&ramp), 0.25)
        XCTAssertEqual(ABGainNext(&ramp), 0.25)
        XCTAssertEqual(ramp.remaining, 0)
    }
    func testRetargetContinuesFromCurrentValue() {
        var ramp = ABGainRamp(current: 1, target: 1, step: 0, remaining: 0)
        ABGainRetarget(&ramp, 0, 4)
        XCTAssertEqual(ABGainNext(&ramp), 0.75)
        ABGainRetarget(&ramp, 1, 2)
        XCTAssertEqual(ABGainNext(&ramp), 0.875)
        XCTAssertEqual(ABGainNext(&ramp), 1)
        ABGainRetarget(&ramp, -.infinity, 4)
        XCTAssertEqual(ABGainNext(&ramp), 1)
    }
}
