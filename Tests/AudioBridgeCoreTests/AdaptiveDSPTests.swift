import AudioBridgeCore
import AudioBridgeRealtime
import Foundation
import XCTest

private func ringRead(_ context: UnsafeMutableRawPointer?, _ samples: UnsafeMutablePointer<Float>?, _ frames: UInt32) -> UInt32 {
    guard let context else { return 0 }
    return ABRingRead(OpaquePointer(context), samples, frames)
}

/// Written for later execution; no HAL or plugin instantiation.
final class AdaptiveDSPTests: XCTestCase {
    func testClockOffsetsConvergeWithBoundedOccupancy() {
        for offset in [-200.0, -100, -50, 50, 100, 200] {
            var controller = ABDriftController()
            var occupancy = 2048.0
            for _ in 0..<100000 {
                let ratio = ABDriftStep(&controller, occupancy, 2048, 48000, 512)
                occupancy += 512 * (1 + offset * 1e-6 - ratio)
                XCTAssertTrue((16...8192).contains(occupancy))
                XCTAssertTrue((0.999...1.001).contains(ratio))
            }
            XCTAssertEqual(controller.ppm, offset, accuracy: 5)
            XCTAssertEqual(occupancy, 2048, accuracy: 20)
        }
    }
    func testResamplerDCIsolationAndStarvation() throws {
        let ring = try XCTUnwrap(ABRingCreate(4096)); defer { ABRingDestroy(ring) }
        let resampler = try XCTUnwrap(ABResamplerCreate()); defer { ABResamplerDestroy(resampler) }
        let signal = (0..<1024).flatMap { _ in [Float(0.25), Float(-0.5)] }
        XCTAssertEqual(signal.withUnsafeBufferPointer { ABRingWrite(ring, $0.baseAddress, 1024) }, 1024)
        var output = [Float](repeating: 0, count: 1024)
        let produced = output.withUnsafeMutableBufferPointer {
            ABResamplerProcess(resampler, ringRead, UnsafeMutableRawPointer(ring), $0.baseAddress, 512, 1.0002)
        }
        XCTAssertEqual(produced, 512)
        for frame in 64..<512 {
            XCTAssertEqual(output[frame * 2], 0.25, accuracy: 0.00001)
            XCTAssertEqual(output[frame * 2 + 1], -0.5, accuracy: 0.00001)
        }
        _ = output.withUnsafeMutableBufferPointer {
            ABResamplerProcess(resampler, ringRead, UnsafeMutableRawPointer(ring), $0.baseAddress, 512, 1.0002)
        }
        XCTAssertTrue(ABResamplerStarved(resampler))
    }
    func testExactCallbackBoundaryAndHistorySurviveEmptyRead() throws {
        let ring = try XCTUnwrap(ABRingCreate(1024)); defer { ABRingDestroy(ring) }
        let resampler = try XCTUnwrap(ABResamplerCreate()); defer { ABResamplerDestroy(resampler) }
        var output = [Float](repeating: 0, count: 64)
        func feed(_ frames: UInt32) {
            let signal = [Float](repeating: 0.25, count: Int(frames) * 2)
            XCTAssertEqual(signal.withUnsafeBufferPointer { ABRingWrite(ring, $0.baseAddress, frames) }, frames)
        }
        func render() -> UInt32 {
            output.withUnsafeMutableBufferPointer {
                ABResamplerProcess(resampler, ringRead, UnsafeMutableRawPointer(ring), $0.baseAddress, 32, 1)
            }
        }
        XCTAssertEqual(ABResamplerInputNeeded(resampler, 32, 1), 48)
        feed(48)
        XCTAssertEqual(render(), 32)
        XCTAssertFalse(ABResamplerStarved(resampler))
        XCTAssertEqual(ABRingAvailable(ring), 0)
        XCTAssertEqual(render(), 0)
        XCTAssertTrue(ABResamplerStarved(resampler))
        XCTAssertEqual(ABResamplerInputNeeded(resampler, 32, 1), 32)
        feed(32)
        XCTAssertEqual(render(), 32)
        XCTAssertFalse(ABResamplerStarved(resampler))
        for sample in output { XCTAssertEqual(sample, 0.25, accuracy: 0.00001) }
    }
    func testDemandMatchesConsumptionAcrossRatios() throws {
        for ratio in [0.999, 1.0, 1.001] {
            let ring = try XCTUnwrap(ABRingCreate(1024)); defer { ABRingDestroy(ring) }
            let resampler = try XCTUnwrap(ABResamplerCreate()); defer { ABResamplerDestroy(resampler) }
            var output = [Float](repeating: 0, count: 64)
            for _ in 0..<128 {
                let needed = ABResamplerInputNeeded(resampler, 32, ratio)
                let signal = [Float](repeating: 0.25, count: Int(needed) * 2)
                XCTAssertEqual(signal.withUnsafeBufferPointer { ABRingWrite(ring, $0.baseAddress, needed) }, needed)
                XCTAssertEqual(output.withUnsafeMutableBufferPointer {
                    ABResamplerProcess(resampler, ringRead, UnsafeMutableRawPointer(ring), $0.baseAddress, 32, ratio)
                }, 32)
                XCTAssertFalse(ABResamplerStarved(resampler))
                XCTAssertEqual(ABRingAvailable(ring), 0)
            }
        }
    }
    func testMatrixPresetsAndValidation() {
        let stereo = ChannelMatrix.identity.process(left: 0.2, right: 0.8)
        XCTAssertEqual(stereo.0, 0.2); XCTAssertEqual(stereo.1, 0.8)
        let swap = ChannelMatrix.swap.process(left: 0.2, right: 0.8)
        XCTAssertEqual(swap.0, 0.8); XCTAssertEqual(swap.1, 0.2)
        let mono = ChannelMatrix.mono.process(left: 0.2, right: 0.8)
        XCTAssertEqual(mono.0, 0.5); XCTAssertEqual(mono.1, 0.5)
        let input = ChannelMatrix.inputOne.process(left: 0.2, right: 0.8)
        XCTAssertEqual(input.0, 0.2); XCTAssertEqual(input.1, 0.2)
        XCTAssertFalse(ChannelMatrix(a: .nan).isValid)
        XCTAssertFalse(ChannelMatrix(d: 1.01).isValid)
    }
}
