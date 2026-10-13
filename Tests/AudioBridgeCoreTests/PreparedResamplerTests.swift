import AudioBridgeRealtime
import Foundation
import XCTest

private func preparedRead(_ context: UnsafeMutableRawPointer?, _ samples: UnsafeMutablePointer<Float>?, _ frames: UInt32) -> UInt32 {
    guard let context else { return 0 }; return ABRingRead(OpaquePointer(context), samples, frames)
}
final class PreparedResamplerTests: XCTestCase {
    func testPreparedMatchesLegacyAcrossFractionBoundariesAndShortReads() throws {
        for ratio in [0.999, 0.999999999999, 1, 1.000000000001, 1.001] {
            let a = try XCTUnwrap(ABResamplerCreate()), b = try XCTUnwrap(ABResamplerCreate())
            let ra = try XCTUnwrap(ABRingCreate(1024)), rb = try XCTUnwrap(ABRingCreate(1024))
            defer { ABResamplerDestroy(a); ABResamplerDestroy(b); ABRingDestroy(ra); ABRingDestroy(rb) }
            for block in 0..<128 {
                if block == 64 { ABResamplerReset(a); ABResamplerReset(b) }
                let frames: UInt32 = [16, 32, 64, 128][block % 4]
                var plan = ABResamplerPrepare(a, frames, ratio)
                XCTAssertEqual(plan.needed, ABResamplerInputNeeded(b, frames, ratio))
                let feed = block % 7 == 0 ? plan.needed / 2 : plan.needed
                let signal = (0..<Int(feed)).flatMap { i in [Float(sin(Double(i + block) * 0.07)), Float(-0.3)] }
                XCTAssertEqual(signal.withUnsafeBufferPointer { ABRingWrite(ra, $0.baseAddress, feed) }, feed)
                XCTAssertEqual(signal.withUnsafeBufferPointer { ABRingWrite(rb, $0.baseAddress, feed) }, feed)
                var oa = [Float](repeating: 9, count: Int(frames) * 2), ob = oa
                let countA = oa.withUnsafeMutableBufferPointer { ABResamplerProcessPrepared(a, preparedRead, UnsafeMutableRawPointer(ra), $0.baseAddress, &plan) }
                let countB = ob.withUnsafeMutableBufferPointer { ABResamplerProcess(b, preparedRead, UnsafeMutableRawPointer(rb), $0.baseAddress, frames, ratio) }
                XCTAssertEqual(countA, countB); XCTAssertEqual(oa, ob)
                XCTAssertEqual(ABRingAvailable(ra), ABRingAvailable(rb))
                XCTAssertEqual(ABResamplerStarved(a), ABResamplerStarved(b))
                XCTAssertFalse(ABResamplerPlanValid(a, &plan))
            }
        }
    }
    func testStaleResetOrWrongOwnerPlanCannotConsumeSource() throws {
        let a = try XCTUnwrap(ABResamplerCreate()), b = try XCTUnwrap(ABResamplerCreate())
        let ring = try XCTUnwrap(ABRingCreate(128))
        defer { ABResamplerDestroy(a); ABResamplerDestroy(b); ABRingDestroy(ring) }
        var plan = ABResamplerPrepare(a, 32, 1)
        var output = [Float](repeating: 9, count: 64)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { ABResamplerProcessPrepared(b, preparedRead, UnsafeMutableRawPointer(ring), $0.baseAddress, &plan) }, 0)
        ABResamplerReset(a)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { ABResamplerProcessPrepared(a, preparedRead, UnsafeMutableRawPointer(ring), $0.baseAddress, &plan) }, 0)
        XCTAssertEqual(output, [Float](repeating: 9, count: 64))
    }
}
