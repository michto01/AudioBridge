import AudioBridgeCore
import AudioBridgeRealtime
import Foundation
import XCTest

/// Deferred sources only: no hardware or plugin execution.
final class DelayEstimateTests: XCTestCase {
    private func stream(_ id: UInt32, start: UInt32, latency: UInt32?) -> StreamFacts {
        let format = StreamFormat(formatID: "lpcm", sampleRate: 48000, channels: 2,
            bitsPerChannel: 32, bytesPerFrame: 8, bytesPerPacket: 8, framesPerPacket: 1,
            flags: 0, isPCM: true, isFloat: true, isSignedInteger: false,
            isNonInterleaved: false, isBigEndian: false, isPacked: true)
        return StreamFacts(runtimeID: id, startingChannel: start, virtualFormat: format, physicalFormat: format,
            availableVirtualFormats: [], availablePhysicalFormats: [], latencyFrames: latency)
    }
    private func estimate(missing: Bool = false, bypassed: Bool = false, rate: Double = 48000) -> DelayEstimate {
        let input = DeviceFacts(runtimeID: 1, uid: "i", name: "Input", bufferFrames: 64,
            input: DirectionFacts(streams: [stream(1, start: 1, latency: 24), stream(2, start: 3, latency: 999)],
                latencyFrames: missing ? nil : 48, safetyOffsetFrames: 16))
        let output = DeviceFacts(runtimeID: 2, uid: "o", name: "Output", bufferFrames: 128,
            output: DirectionFacts(streams: [stream(3, start: 1, latency: 12)], latencyFrames: 32, safetyOffsetFrames: 8))
        var selection = RouteSelection()
        selection.inputMix = [InputPatch(channel: 1, left: 1, right: 1)]
        selection.outputMap = [OutputPatch(channel: 1, source: .left), OutputPatch(channel: 2, source: .right)]
        return DelayEstimate(input: input, output: output, selection: selection, sampleRate: rate,
            captureQueue: 64, processedQueue: 128, inFlight: 32, lookahead: 17,
            auLatencySeconds: 0.01, bypassed: bypassed)
    }
    func testAccountingIncludesOnlyRoutedStreamsAndDoesNotAddStartupFill() {
        let value = estimate()
        XCTAssertTrue(value.complete)
        // Hardware reports/buffers 332 + actual queues/inflight 224 + FIR17 + AU480.
        XCTAssertEqual(value.knownFrames, 1053)
        XCTAssertEqual(value.totalMilliseconds ?? -1, 1053.0 / 48, accuracy: 1e-8)
        XCTAssertEqual(estimate(bypassed: true).knownFrames, 573)
    }
    func testUnknownDriverValueRemainsUnknownAndInvalidRateHasNoMilliseconds() {
        XCTAssertFalse(estimate(missing: true).complete)
        XCTAssertNil(estimate(missing: true).totalMilliseconds)
        XCTAssertNil(estimate(rate: 0).milliseconds(10))
        XCTAssertNil(estimate(rate: .nan).milliseconds(10))
    }
    func testReportedScreenshotSeparatesSmallBridgeBuffersFromStreamLatency() {
        let input = DeviceFacts(runtimeID: 1, uid: "i", name: "Input", bufferFrames: 32,
            input: DirectionFacts(streams: [stream(1, start: 1, latency: 1439)], latencyFrames: 0, safetyOffsetFrames: 74))
        let output = DeviceFacts(runtimeID: 2, uid: "o", name: "Output", bufferFrames: 32,
            output: DirectionFacts(streams: [stream(2, start: 1, latency: 690)], latencyFrames: 70, safetyOffsetFrames: 74))
        var selection = RouteSelection()
        selection.inputMix = [InputPatch(channel: 1, left: 1, right: 1)]
        selection.outputMap = [OutputPatch(channel: 1, source: .left), OutputPatch(channel: 2, source: .right)]
        let value = DelayEstimate(input: input, output: output, selection: selection, sampleRate: 48000,
            captureQueue: 32, processedQueue: 105, inFlight: 0, lookahead: 17, auLatencySeconds: 0, bypassed: false)
        XCTAssertEqual(value.subtotalMilliseconds(categories: [.bridge, .callbackBuffer]) ?? -1, 218.0 / 48, accuracy: 1e-8)
        XCTAssertEqual(value.subtotalMilliseconds(categories: [.deviceReported]) ?? -1, 2347.0 / 48, accuracy: 1e-8)
        XCTAssertEqual(value.totalMilliseconds ?? -1, 2565.0 / 48, accuracy: 1e-8)
    }
    func testBufferDraftPrefersRealDriverValueAndOtherwise64() {
        XCTAssertEqual(BufferFrameChoices.initialRequest(current: 64, range: nil), 64)
        XCTAssertEqual(BufferFrameChoices.initialRequest(current: 96, range: nil), 96)
        XCTAssertEqual(BufferFrameChoices.initialRequest(current: 512, range: nil), 512)
        XCTAssertEqual(BufferFrameChoices.initialRequest(current: nil, range: nil), 64)
        XCTAssertEqual(BufferFrameChoices.initialRequest(current: nil, range: .init(minimum: 256, maximum: 1024)), 256)
        XCTAssertEqual(BufferFrameChoices.initialRequest(current: nil, range: .init(minimum: .nan, maximum: 1024)), 64)
    }
    func testConservedPendingReplacesOverlappingQueueAndInFlightReports() {
        let value = DelayEstimate(input: nil, output: nil, selection: RouteSelection(), sampleRate: 48000,
            captureQueue: 64, processedQueue: 128, inFlight: 64, lookahead: 17,
            auLatencySeconds: 0, bypassed: false, pendingSourceFrames: 192)
        XCTAssertEqual(value.subtotalMilliseconds(categories: [.bridge]) ?? -1, 209.0 / 48, accuracy: 1e-8)
        XCTAssertEqual(value.components.filter { $0.category == .bridge }.count, 3)
        XCTAssertFalse(value.complete) // Device properties remain unknown.
    }
    func testLatencyChangesDoNotInvalidateRoutingTopology() {
        let a = DirectionFacts(streams: [stream(1, start: 1, latency: 20)], latencyFrames: 30)
        let b = DirectionFacts(streams: [stream(1, start: 1, latency: 40)], latencyFrames: 60)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.matchesRoutingTopology(b))
        XCTAssertFalse(a.matchesRoutingTopology(DirectionFacts(streams: [stream(1, start: 3, latency: 20)])))
    }
    func testHelperTimingPublishesWithoutAudioOrAPlugin() throws {
        let name = "/abt" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(22)
        let transport = try XCTUnwrap(ABAUTransportCreate(String(name), 1024))
        defer { ABAUTransportClose(transport) }
        let start = ABAUTransportBeginBlock(transport, 64)
        XCTAssertEqual(ABAUTransportSnapshot(transport).inFlightFrames, 64)
        ABAUTransportEndBlock(transport, start)
        let snapshot = ABAUTransportSnapshot(transport)
        XCTAssertEqual(snapshot.inFlightFrames, 0)
        XCTAssertEqual(snapshot.renderBlocks, 1)
        XCTAssertEqual(snapshot.renderNanoseconds, snapshot.lastRenderNanoseconds)
        XCTAssertEqual(snapshot.maxRenderNanoseconds, snapshot.lastRenderNanoseconds)
    }
}
