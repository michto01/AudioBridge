import AudioBridgeRealtime
import Foundation
import XCTest

/// Pure FIFO checks only. These do not start HAL, validate a device, or exercise drift correction.
final class RealtimeRingTests: XCTestCase {
    func testCapacityMustBeBoundedPowerOfTwo() {
        XCTAssertNil(ABRingCreate(0))
        XCTAssertNil(ABRingCreate(3))
        XCTAssertNil(ABRingCreate(131072))
    }

    func testWrapOverflowAndStarvation() throws {
        let ring = try XCTUnwrap(ABRingCreate(4))
        defer { ABRingDestroy(ring) }
        let first: [Float] = [1, 10, 2, 20, 3, 30]
        XCTAssertEqual(first.withUnsafeBufferPointer { ABRingWrite(ring, $0.baseAddress, 3) }, 3)
        var output = [Float](repeating: -1, count: 4)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { ABRingRead(ring, $0.baseAddress, 2) }, 2)
        XCTAssertEqual(output, [1, 10, 2, 20])
        let second: [Float] = [4, 40, 5, 50, 6, 60, 7, 70]
        XCTAssertEqual(second.withUnsafeBufferPointer { ABRingWrite(ring, $0.baseAddress, 4) }, 3)
        XCTAssertEqual(ABRingAvailable(ring), 4)
        output = [Float](repeating: -1, count: 12)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { ABRingRead(ring, $0.baseAddress, 6) }, 4)
        XCTAssertEqual(output, [3, 30, 4, 40, 5, 50, 6, 60, 0, 0, 0, 0])
        XCTAssertEqual(ABRingAvailable(ring), 0)
    }

    func testOneKilohertzSignalKeepsLanesSeparate() throws {
        let ring = try XCTUnwrap(ABRingCreate(1024))
        defer { ABRingDestroy(ring) }
        for lane in 0...1 {
            var input = [Float](repeating: 0, count: 960)
            for frame in 0..<480 {
                input[frame * 2 + lane] = Float(0.1 * sin(2 * Double.pi * 1000 * Double(frame) / 48000))
            }
            XCTAssertEqual(input.withUnsafeBufferPointer { ABRingWrite(ring, $0.baseAddress, 480) }, 480)
            var output = [Float](repeating: -1, count: 960)
            XCTAssertEqual(output.withUnsafeMutableBufferPointer { ABRingRead(ring, $0.baseAddress, 480) }, 480)
            XCTAssertEqual(output, input)
            for frame in 0..<480 { XCTAssertEqual(output[frame * 2 + (1 - lane)], 0) }
        }
    }
}
