import AudioBridgeCore
import AudioBridgeEngine
import AudioBridgeRealtime
import Foundation
import XCTest

/// Written for later execution; does not instantiate devices or plugins.
final class StereoRoutingTests: XCTestCase {
    func testMonoAndStereoDefaultPatches() {
        var route = RouteSelection()
        route.inputMix = [InputPatch(channel: 7, left: 1, right: 1)]
        let mono = route.mix([7: 0.25]); XCTAssertEqual(mono.0, 0.25); XCTAssertEqual(mono.1, 0.25)
        route.inputMix = [InputPatch(channel: 7, left: 1), InputPatch(channel: 8, right: 1)]
        let stereo = route.mix([7: 0.25, 8: -0.5]); XCTAssertEqual(stereo.0, 0.25); XCTAssertEqual(stereo.1, -0.5)
    }
    func testManyInputsMixWithoutHiddenNormalization() {
        var route = RouteSelection()
        route.inputMix = [InputPatch(channel: 7, left: 1), InputPatch(channel: 8, right: 1), InputPatch(channel: 11, left: 0.5, right: 0.5)]
        let mix = route.mix([7: 0.25, 8: -0.25, 11: 0.5])
        XCTAssertEqual(mix.0, 0.5); XCTAssertEqual(mix.1, 0)
        XCTAssertTrue(route.headroomWarning)
        route.inputMix.append(InputPatch(channel: 7, right: 1))
        XCTAssertFalse(route.patchesValid)
        XCTAssertFalse(InputPatch(channel: 1, left: .nan).isValid)
        XCTAssertFalse(InputPatch(channel: 0).isValid)
        XCTAssertFalse(InputPatch(channel: 1, right: 2.01).isValid)
    }
    func testLegacyMigrationRetainsUIDsAndDuplicatedMappings() throws {
        let suite = "AudioBridgeTests.\(UUID().uuidString)", key = "AudioBridge.routeSelection"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data(#"{"schemaVersion":1,"input":{"uid":"mic","lane1":7,"lane2":7},"output":{"uid":"out","lane1":4,"lane2":4}}"#.utf8)
        defaults.set(data, forKey: key)
        let matrix = ChannelMatrix(a: 1, b: 1, c: 1, d: 0)
        defaults.set(try JSONEncoder().encode(matrix), forKey: "AudioBridge.matrix")
        let store = SelectionStore(defaults: defaults), result = try store.load()
        XCTAssertEqual(result.schemaVersion, 2)
        XCTAssertEqual(result.input.uid, "mic"); XCTAssertEqual(result.output.uid, "out")
        XCTAssertEqual(result.inputMix, [InputPatch(channel: 7, left: 2, right: 1)])
        XCTAssertEqual(result.outputMap, [OutputPatch(channel: 4, source: .mono)])
        XCTAssertNil(result.input.lane1)
        XCTAssertEqual(defaults.data(forKey: key + ".v1Backup"), data)
        XCTAssertEqual(try store.load(), result)
    }
    func testMissingChannelsRetainedWithoutFallback() {
        var route = RouteSelection()
        route.input = EndpointSelection(uid: "missing")
        route.inputMix = [InputPatch(channel: 42, left: 1)]
        XCTAssertNotNil(route.issue(in: [], direction: .input))
        XCTAssertEqual(route.inputMix[0].channel, 42)
    }
    private func stream(_ start: UInt32, channels: UInt32, planar: Bool = false) -> StreamFacts {
        let format = StreamFormat(formatID: "lpcm", sampleRate: 48000, channels: channels,
            bitsPerChannel: 32, bytesPerFrame: planar ? 4 : channels * 4,
            bytesPerPacket: planar ? 4 : channels * 4, framesPerPacket: 1, flags: 0,
            isPCM: true, isFloat: true, isSignedInteger: false, isNonInterleaved: planar, isBigEndian: false, isPacked: true)
        return StreamFacts(runtimeID: start, startingChannel: start, virtualFormat: format, physicalFormat: format,
            availableVirtualFormats: [], availablePhysicalFormats: [])
    }
    func testMultipleStreamsPreservePhysicalIndicesAndBufferAddresses() throws {
        let input = DirectionFacts(channelCount: 3, bufferChannelCounts: [2, 1], streams: [stream(7, channels: 2), stream(11, channels: 1, planar: true)])
        let output = DirectionFacts(channelCount: 4, bufferChannelCounts: [2, 1, 1], streams: [stream(1, channels: 2), stream(3, channels: 2, planar: true)])
        let devices = [DeviceFacts(runtimeID: 1, uid: "in", name: "Aggregate input", alive: true, nominalSampleRate: 48000, bufferFrames: 512, input: input),
                       DeviceFacts(runtimeID: 2, uid: "out", name: "Aggregate output", alive: true, nominalSampleRate: 48000, bufferFrames: 512, output: output)]
        var route = RouteSelection(); route.input = EndpointSelection(uid: "in"); route.output = EndpointSelection(uid: "out")
        route.inputMix = [InputPatch(channel: 8, left: 1), InputPatch(channel: 11, right: 1)]
        route.outputMap = [OutputPatch(channel: 1, source: .left), OutputPatch(channel: 3, source: .right), OutputPatch(channel: 4, source: .left)]
        let plan = try Phase2Plan(selection: route, devices: devices)
        XCTAssertEqual(plan.input.physicalChannels, [7, 8, 11])
        XCTAssertEqual(plan.input.addresses[1].buffer, 0); XCTAssertEqual(plan.input.addresses[1].offset, 1)
        XCTAssertEqual(plan.input.addresses[2].buffer, 1)
        XCTAssertEqual(plan.output.addresses[3].buffer, 2)
        XCTAssertEqual(plan.input.inputGains(route), [0, 0, 1, 0, 0, 1])
        XCTAssertEqual(plan.output.outputGains(route), [1, 0, 0, 0, 0, 1, 1, 0])
    }
    func testCPhysicalMixAndStereoCopies() throws {
        let inputs = [ABChannelAddress(buffer: 0, offset: 0, stride: 3), ABChannelAddress(buffer: 0, offset: 1, stride: 3), ABChannelAddress(buffer: 0, offset: 2, stride: 3)]
        let outputs = (0..<5).map { ABChannelAddress(buffer: 0, offset: UInt32($0), stride: 5) }
        let routing = try XCTUnwrap(ABRoutingCreate(inputs, 3, [3], 1, [1, 0, 0, 1, 0.5, 0.5], outputs, 5, [5], 1, [1, 0, 0, 1, 1, 0, 0, 1, 0, 0]))
        defer { ABRoutingDestroy(routing) }
        let input = UnsafeMutablePointer<Float>.allocate(capacity: 3), output = UnsafeMutablePointer<Float>.allocate(capacity: 5)
        defer { input.deallocate(); output.deallocate() }
        input.initialize(from: [0.25, -0.25, 0.5], count: 3)
        output.initialize(repeating: 9, count: 5)
        let inList = UnsafeMutableAudioBufferListPointer.allocate(maximumBuffers: 1)
        let outList = UnsafeMutableAudioBufferListPointer.allocate(maximumBuffers: 1)
        defer { inList.unsafeMutablePointer.deallocate(); outList.unsafeMutablePointer.deallocate() }
        inList[0] = AudioBuffer(mNumberChannels: 3, mDataByteSize: 12, mData: input)
        outList[0] = AudioBuffer(mNumberChannels: 5, mDataByteSize: 20, mData: output)
        var frames: UInt32 = 0, faults: UInt64 = 0, rawL: UInt64 = 0, rawR: UInt64 = 0
        XCTAssertTrue(ABRoutingFrames(routing, inList.unsafeMutablePointer, true, &frames)); XCTAssertEqual(frames, 1)
        var stereo = [Float](repeating: 0, count: 2)
        stereo.withUnsafeMutableBufferPointer { ABRoutingMix(routing, inList.unsafeMutablePointer, $0.baseAddress, 1, 0, &faults, &rawL, &rawR) }
        XCTAssertEqual(stereo, [0.5, 0])
        var peak: Float = 0, clips: UInt64 = 0
        stereo.withUnsafeBufferPointer { ABRoutingFanout(routing, $0.baseAddress, outList.unsafeMutablePointer, 1, 0, &faults, &peak, &clips) }
        XCTAssertEqual(Array(UnsafeBufferPointer(start: output, count: 5)), [0.5, 0, 0.5, 0, 0])
        XCTAssertEqual(faults, 0)
        XCTAssertTrue(ABRoutingSetOutput(routing, [0, 0, 0, 0, 0, 0, 0, 0, 1, 1], 5, false))
        stereo = [0.75, 0.75]
        stereo.withUnsafeBufferPointer { ABRoutingFanout(routing, $0.baseAddress, outList.unsafeMutablePointer, 1, 0, &faults, &peak, &clips) }
        XCTAssertEqual(output[4], 1.5); XCTAssertEqual(clips, 1)
    }
    func testStatusNeedsFreshCallbacksAndBuffers() {
        func state(primed: Bool = true, fresh: Bool = true, glitches: Bool = false, fault: Bool = false) -> RoutingActivity {
            .resolve(fault: fault, requested: true, transitioning: false, configured: true,
                configurationFault: false, primed: primed, callbacksFresh: fresh, deliveredFrames: true, buffered: true, glitches: glitches)
        }
        XCTAssertEqual(state(), .running)
        XCTAssertEqual(state(primed: false), .starting)
        XCTAssertEqual(state(fresh: false), .degraded)
        XCTAssertEqual(state(glitches: true), .degraded)
        XCTAssertEqual(state(fault: true), .actionRequired)
    }
    func testClipIsSignalLevelAndOnlyDeliveryFaultsAreGlitches() {
        let clipped = MeterLevel(amplitude: 1.2, clippedSamples: 500)
        XCTAssertGreaterThan(clipped.clippedSamples, 0)
        let glitches = RoutingActivity.hasGlitches(underrunFrames: 0, overrunFrames: 0, formatFaults: 0)
        XCTAssertFalse(glitches)
        XCTAssertEqual(RoutingActivity.resolve(fault: false, requested: true, transitioning: false,
            configured: true, configurationFault: false, primed: true, callbacksFresh: true,
            deliveredFrames: true, buffered: true, glitches: glitches), .running)
        XCTAssertTrue(RoutingActivity.hasGlitches(underrunFrames: 1, overrunFrames: 0, formatFaults: 0))
        XCTAssertTrue(RoutingActivity.hasGlitches(underrunFrames: 0, overrunFrames: 1, formatFaults: 0))
        XCTAssertTrue(RoutingActivity.hasGlitches(underrunFrames: 0, overrunFrames: 0, formatFaults: 1))
    }
}
