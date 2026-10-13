import AudioBridgeAU
import AudioBridgeCore
import AudioBridgeRealtime
import Foundation
import XCTest

final class AuditCorrectionTests: XCTestCase {
    private func packet(_ address: String, _ tags: String, _ word: UInt32? = nil) -> Data {
        func padded(_ value: String) -> Data { var d = Data(value.utf8); d.append(0); while d.count % 4 != 0 { d.append(0) }; return d }
        var data = padded(address) + padded(tags)
        if let word { data.append(contentsOf: [UInt8(truncatingIfNeeded: word >> 24), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)]) }
        return data
    }
    func testOSCIntegerBypassAndFloatGain() {
        for word: UInt32 in [0, 1] {
            XCTAssertEqual(RemoteOSCDecoder.command(packet("/audiobridge/effects/bypass", ",i", word), gainRange: -60...12), .chainBypass(word == 1))
        }
        for word: UInt32 in [2, UInt32.max] {
            XCTAssertNil(RemoteOSCDecoder.command(packet("/audiobridge/effects/bypass", ",i", word), gainRange: -60...12))
        }
        XCTAssertEqual(RemoteOSCDecoder.command(packet("/audiobridge/input/gain", ",f", Float(-6).bitPattern), gainRange: -60...12), .inputGain(-6))
        XCTAssertEqual(RemoteOSCDecoder.command(packet("/audiobridge/output/gain", ",f", Float(3).bitPattern), gainRange: -60...12), .outputGain(3))
    }
    func testOSCRejectsTruncationWrongTagsExtraArgumentsAndNonfiniteGain() {
        let p = packet("/audiobridge/effects/bypass", ",i", 1)
        XCTAssertNil(RemoteOSCDecoder.command(Data(p.dropLast()), gainRange: -60...12))
        XCTAssertNil(RemoteOSCDecoder.command(p + Data([0]), gainRange: -60...12))
        XCTAssertNil(RemoteOSCDecoder.command(packet("/audiobridge/effects/bypass", ",f", Float(1).bitPattern), gainRange: -60...12))
        for gain: Float in [.nan, .infinity, 13, -61] {
            XCTAssertNil(RemoteOSCDecoder.command(packet("/audiobridge/input/gain", ",f", gain.bitPattern), gainRange: -60...12))
        }
        XCTAssertEqual(RemoteOSCDecoder.command(packet("/audiobridge/start", ","), gainRange: -60...12), .start)
        XCTAssertNil(RemoteOSCDecoder.command(packet("/audiobridge/start", ",i", 1), gainRange: -60...12))
    }
    func testServiceDisableAndRestartRejectAcceptedOldCallbacks() {
        var http = RemoteServiceEpoch(), osc = RemoteServiceEpoch()
        let acceptedHTTP = http.activate(), acceptedOSC = osc.activate()
        XCTAssertTrue(http.accepts(acceptedHTTP))
        http.invalidate()
        // Models a request accepted earlier, resuming after service shutdown.
        var commands = 0
        if http.accepts(acceptedHTTP) { commands += 1 }
        XCTAssertEqual(commands, 0); XCTAssertTrue(osc.accepts(acceptedOSC))
        let replacement = http.activate()
        var status = "ready"
        if http.accepts(acceptedHTTP) { status = "cancelled" }
        XCTAssertEqual(status, "ready"); XCTAssertTrue(http.accepts(replacement))
        osc.invalidate(); XCTAssertFalse(osc.accepts(acceptedOSC))
    }
    func testPartialHTTPRequestCompletedAfterDisableCannotDispatch() throws {
        var session = RemoteServiceEpoch()
        let accepted = session.activate()
        let body = Data("{\"command\":\"start\"}".utf8)
        let head = Data("POST /api/v1/control HTTP/1.1\r\nAuthorization: Bearer test-token\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        XCTAssertNil(RemoteHTTPDecoder.frame(head))
        session.invalidate()
        let request = try XCTUnwrap(RemoteHTTPDecoder.frame(head + body))
        XCTAssertEqual(request.path, "/api/v1/control")
        XCTAssertEqual(request.headers["authorization"], "Bearer test-token")
        XCTAssertEqual(request.body, body)
        var commands = 0
        if session.accepts(accepted) { commands += 1 }
        XCTAssertEqual(commands, 0)
    }
    func testEditorSerializationFailurePreservesStateAndCompletionIsOnce() throws {
        var effect = AUEffect(identity: .init(type: 1, subtype: 2, manufacturer: 3), name: "Test")
        effect.state = Data([1, 2, 3])
        XCTAssertThrowsError(try AUEditorState.savedEffect(effect, state: ["bad": NSObject()]))
        XCTAssertThrowsError(try AUEditorState.savedEffect(effect, state: ["large": Data(repeating: 0, count: 8 * 1024 * 1024 + 1)]))
        XCTAssertEqual(effect.state, Data([1, 2, 3]))
        let saved = try AUEditorState.savedEffect(effect, state: ["value": 4])
        XCTAssertNotEqual(saved.state, effect.state)
        var completions = 0
        let completion = AUOnceCompletion<String> { _ in completions += 1 }
        completion.finish("save failed"); completion.finish("window close")
        XCTAssertEqual(completions, 1)
        let subsequent = AUOnceCompletion<String> { _ in completions += 1 }
        subsequent.finish("new edit"); XCTAssertEqual(completions, 2)
    }
    func testStartCancellationIsIrreversibleAndEngineRetainsGate() throws {
        let gate = try XCTUnwrap(ABStartGateCreate())
        let engine = try XCTUnwrap(ABEngineCreate(1, 2, 1024, 128))
        XCTAssertTrue(ABEngineAttachStartGate(engine, gate))
        XCTAssertFalse(ABStartGateCancelled(gate))
        ABStartGateCancel(gate)
        // Pre-start cancellation rejects before making any HAL call.
        XCTAssertNotEqual(ABEngineStart(engine), 0)
        ABStartGateRelease(gate) // Engine still owns the cancelled token.
        XCTAssertTrue(ABEngineDestroy(engine))
        let next = try XCTUnwrap(ABStartGateCreate())
        XCTAssertFalse(ABStartGateCancelled(next)); ABStartGateRelease(next)
    }
    func testCompleteCycleAccountingIncludesSeparateAdoptionAndBudget() throws {
        let name = "/abcy" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(21)
        let t = try XCTUnwrap(ABAUTransportCreate(String(name), 1024)); defer { ABAUTransportClose(t) }
        ABAUTransportUnlink(t); ABAUTransportConfigureTiming(t, 1000)
        ABAUTransportRecordCycleDuration(t, 1000, 200, true)
        ABAUTransportRecordCycleDuration(t, 1500, 0, false)
        let cycle = ABAUTransportSnapshot(t).cycle
        XCTAssertEqual(cycle.cycles, 2); XCTAssertEqual(cycle.nanoseconds, 2500)
        XCTAssertEqual(cycle.lastNanoseconds, 1500); XCTAssertEqual(cycle.maximumNanoseconds, 1500)
        XCTAssertEqual(cycle.overBudget, 1); XCTAssertEqual(cycle.adoptions, 1)
        XCTAssertEqual(cycle.adoptionNanoseconds, 200); XCTAssertEqual(cycle.maximumAdoptionNanoseconds, 200)
        XCTAssertEqual(ABAUTransportSnapshot(t).renderBlocks, 0)
        XCTAssertEqual(ABAUTransportProtocolVersion(), 8)
    }
    func testAvailableCapabilitiesAreNotActiveTopology() {
        let format = StreamFormat(formatID: "lpcm", sampleRate: 48000, channels: 2, bitsPerChannel: 32,
            bytesPerFrame: 8, bytesPerPacket: 8, framesPerPacket: 1, flags: 0,
            isPCM: true, isFloat: true, isSignedInteger: false, isNonInterleaved: false, isBigEndian: false, isPacked: true)
        let stream = StreamFacts(runtimeID: 1, startingChannel: 1, virtualFormat: nil, physicalFormat: nil,
            availableVirtualFormats: [], availablePhysicalFormats: [])
        let baseline = DirectionFacts(channelCount: 2, bufferChannelCounts: [2], streams: [stream])
        XCTAssertTrue(baseline.matchesRoutingTopology(baseline))
        XCTAssertFalse(baseline.matchesRoutingTopology(DirectionFacts(channelCount: 1, bufferChannelCounts: [1], streams: [stream])))
        XCTAssertFalse(baseline.matchesRoutingTopology(DirectionFacts(channelCount: 2, bufferChannelCounts: [2], streams: [])))
        XCTAssertTrue(baseline.matchesRoutingTopology(DirectionFacts(channelCount: 2, bufferChannelCounts: [2], streams: [stream], latencyFrames: 42)))
        let capabilityChange = StreamFacts(runtimeID: 1, startingChannel: 1, virtualFormat: nil, physicalFormat: nil,
            availableVirtualFormats: [.init(format: format, sampleRates: .init(minimum: 44100, maximum: 48000))], availablePhysicalFormats: [])
        XCTAssertTrue(baseline.matchesRoutingTopology(DirectionFacts(channelCount: 2, bufferChannelCounts: [2], streams: [capabilityChange])))
        let activeFormatChange = StreamFacts(runtimeID: 1, startingChannel: 1, virtualFormat: format, physicalFormat: nil, availableVirtualFormats: [], availablePhysicalFormats: [])
        XCTAssertFalse(baseline.matchesRoutingTopology(DirectionFacts(channelCount: 2, bufferChannelCounts: [2], streams: [activeFormatChange])))
    }
}
