import AudioBridgeEngine
import AudioBridgeRealtime
import XCTest

/// Written for later execution. No hardware IO is involved.
final class AudioIndicatorTests: XCTestCase {
    func testSilenceUnityAndHalfAmplitude() {
        XCTAssertEqual(MeterLevel(amplitude: 0, clippedSamples: 0).decibels, -.infinity)
        XCTAssertEqual(MeterLevel(amplitude: 1, clippedSamples: 1).decibels, 0)
        XCTAssertEqual(MeterLevel(amplitude: 0.5, clippedSamples: 0).decibels, -6.0206, accuracy: 0.0001)
    }
    func testStereoPeaksAndFullScaleCounts() {
        let samples: [Float] = [0.5, 0, -1, 0.2, 0, -1.2]
        let levels = samples.withUnsafeBufferPointer { ABMeasureStereo($0.baseAddress, 3) }
        XCTAssertEqual(levels.peak1, 1)
        XCTAssertEqual(levels.peak2, 1.2)
        XCTAssertEqual(levels.clips1, 1)
        XCTAssertEqual(levels.clips2, 1)
    }
    func testProvisionalBufferMargins() {
        XCTAssertEqual(BufferProfile.low.targetFrames(deviceBuffer: 512), 1024)
        XCTAssertEqual(BufferProfile.balanced.targetFrames(deviceBuffer: 512), 2048)
        XCTAssertEqual(BufferProfile.robust.targetFrames(deviceBuffer: 512), 4096)
        XCTAssertEqual(BufferProfile.robust.targetFrames(deviceBuffer: 4096), 32768)
    }
}
