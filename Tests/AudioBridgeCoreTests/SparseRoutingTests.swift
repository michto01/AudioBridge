import AudioBridgeRealtime
import CoreAudio
import XCTest

final class SparseRoutingTests: XCTestCase {
    func testSparseInterleavedAndPlanarMatchDenseReferenceThroughRampReversal() throws {
        for planar in [false, true] {
            for channels in [2, 16, 256] {
                let maximumFrames = 16
                let data = UnsafeMutablePointer<Float>.allocate(capacity: channels * maximumFrames)
                let output = UnsafeMutablePointer<Float>.allocate(capacity: channels * maximumFrames)
                data.initialize(repeating: 0, count: channels * maximumFrames)
                output.initialize(repeating: 9, count: channels * maximumFrames)
                let inputList = AudioBufferList.allocate(maximumBuffers: planar ? channels : 1)
                let outputList = AudioBufferList.allocate(maximumBuffers: planar ? channels : 1)
                defer { data.deallocate(); output.deallocate(); inputList.unsafeMutablePointer.deallocate(); outputList.unsafeMutablePointer.deallocate() }
                inputList.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(planar ? channels : 1)
                outputList.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(planar ? channels : 1)
                for c in 0..<channels {
                    for f in 0..<maximumFrames { data[planar ? c * maximumFrames + f : f * channels + c] = Float(c % 7 - 3) / 10 }
                    if planar {
                        inputList[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(maximumFrames * 4), mData: data.advanced(by: c * maximumFrames))
                        outputList[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(maximumFrames * 4), mData: output.advanced(by: c * maximumFrames))
                    }
                }
                if !planar {
                    inputList[0] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(channels * maximumFrames * 4), mData: data)
                    outputList[0] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(channels * maximumFrames * 4), mData: output)
                }
                let addresses = (0..<channels).map { ABChannelAddress(buffer: UInt32(planar ? $0 : 0), offset: UInt32(planar ? 0 : $0), stride: UInt32(planar ? 1 : channels)) }
                let buffers = [UInt32](repeating: UInt32(planar ? 1 : channels), count: planar ? channels : 1)
                var gains = [Float](repeating: 0, count: channels * 2)
                gains[0] = 1; gains[(channels - 1) * 2 + 1] = 1
                let routing = try XCTUnwrap(ABRoutingCreate(addresses, UInt32(channels), buffers, UInt32(buffers.count), gains, addresses, UInt32(channels), buffers, UInt32(buffers.count), gains))
                defer { ABRoutingDestroy(routing) }
                var reference = gains.map { ABGainRamp(current: $0, target: $0, step: 0, remaining: 0) }
                var fanout = reference
                var faults: UInt64 = 0, rawL: UInt64 = 0, rawR: UInt64 = 0, clips: UInt64 = 0
                var peak: Float = 0
                for iteration in 0..<20 {
                    if iteration % 2 == 0 {
                        gains = [Float](repeating: 0, count: channels * 2)
                        if iteration % 4 == 0 { gains[(channels / 2) * 2] = 0.5; gains[(channels - 1) * 2 + 1] = 1 }
                        else { gains[0] = 1; gains[1] = 0.25 }
                        XCTAssertTrue(ABRoutingSetBoth(routing, gains, UInt32(channels), gains, UInt32(channels), false))
                        for i in gains.indices {
                            if reference[i].target != gains[i] { ABGainRetarget(&reference[i], gains[i], 8) }
                            if fanout[i].target != gains[i] { ABGainRetarget(&fanout[i], gains[i], 8) }
                        }
                    }
                    // Some reversals occur before an eight-sample fade completes.
                    let frames = iteration < 10 ? 2 : maximumFrames
                    var mixed = [Float](repeating: 9, count: frames * 2)
                    mixed.withUnsafeMutableBufferPointer { ABRoutingMix(routing, inputList.unsafeMutablePointer, $0.baseAddress, UInt32(frames), 8, &faults, &rawL, &rawR) }
                    for f in 0..<frames {
                        var l: Double = 0, r: Double = 0
                        for c in 0..<channels {
                            let sample = data[planar ? c * maximumFrames + f : f * channels + c]
                            l += Double(sample) * Double(ABGainNext(&reference[c * 2]))
                            r += Double(sample) * Double(ABGainNext(&reference[c * 2 + 1]))
                        }
                        XCTAssertEqual(mixed[f * 2], Float(l)); XCTAssertEqual(mixed[f * 2 + 1], Float(r))
                    }
                    output.update(repeating: 9, count: channels * maximumFrames)
                    mixed.withUnsafeBufferPointer { ABRoutingFanout(routing, $0.baseAddress, outputList.unsafeMutablePointer, UInt32(frames), 8, &faults, &peak, &clips) }
                    for f in 0..<frames { for c in 0..<channels {
                        let expected = ABGainNext(&fanout[c * 2]) * mixed[f * 2] + ABGainNext(&fanout[c * 2 + 1]) * mixed[f * 2 + 1]
                        XCTAssertEqual(output[planar ? c * maximumFrames + f : f * channels + c], expected, accuracy: 0.000001)
                    } }
                }
                XCTAssertEqual(faults, 0)
            }
        }
    }
}
