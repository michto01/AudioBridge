import Foundation
import XCTest
@testable import AudioBridgeCore

final class RouteSelectionTests: XCTestCase {
    private func pcm(channels: Int) -> StreamFormat {
        StreamFormat(formatID: "lpcm", sampleRate: 48_000, channels: UInt32(channels),
            bitsPerChannel: 32, bytesPerFrame: 4, bytesPerPacket: 4, framesPerPacket: 1,
            flags: 0, isPCM: true, isFloat: true, isSignedInteger: false,
            isNonInterleaved: true, isBigEndian: false, isPacked: true)
    }
    private func device(uid: String = "chosen", runtimeID: UInt32 = 10, channels: Int = 2,
                        alive: Bool? = true, withPCM: Bool = true, startingChannel: UInt32 = 1) -> DeviceFacts {
        let stream = StreamFacts(runtimeID: 20, startingChannel: startingChannel,
            virtualFormat: withPCM ? pcm(channels: channels) : nil, physicalFormat: pcm(channels: channels),
            availableVirtualFormats: [], availablePhysicalFormats: [])
        let facts = DirectionFacts(channelCount: channels, streams: [stream])
        return DeviceFacts(runtimeID: runtimeID, uid: uid, name: "Identical display name", alive: alive,
                           input: facts, output: facts)
    }
    func testFirstLaunchNeverSelectsDefault() {
        let selection = RouteSelection()
        XCTAssertNil(selection.input.uid)
        XCTAssertNil(selection.output.uid)
        XCTAssertNotNil(selection.input.issue(in: [device()], direction: .input))
    }
    func testMissingUIDNeverResolvesByNameOrAnotherEndpoint() {
        let selected = EndpointSelection(uid: "chosen", lane1: 1, lane2: 2)
        XCTAssertEqual(selected.issue(in: [device(uid: "system-default")], direction: .output),
                       "Selected output is missing; its UID is retained.")
        XCTAssertEqual(selected.uid, "chosen")
        XCTAssertNil(selected.issue(in: [device(runtimeID: 999)], direction: .output))
    }
    func testChangingChannelLayoutRetainsMappingAndRequiresAction() {
        let selected = EndpointSelection(uid: "chosen", lane1: 1, lane2: 4)
        XCTAssertNil(selected.issue(in: [device(channels: 8)], direction: .input))
        XCTAssertNotNil(selected.issue(in: [device(channels: 2)], direction: .input))
        XCTAssertEqual(selected.lane2, 4)
    }
    func testMonoRequiresTwoExplicitLaneSelections() {
        XCTAssertNotNil(EndpointSelection(uid: "chosen", lane1: 1).issue(in: [device(channels: 1)], direction: .input))
        XCTAssertNil(EndpointSelection(uid: "chosen", lane1: 1, lane2: 1).issue(in: [device(channels: 1)], direction: .input))
        XCTAssertNotNil(EndpointSelection(uid: "chosen", lane1: 0, lane2: 1).issue(in: [device(channels: 1)], direction: .input))
    }
    func testUnknownFormatAndLivenessRequireAction() {
        let selected = EndpointSelection(uid: "chosen", lane1: 1, lane2: 2)
        XCTAssertNotNil(selected.issue(in: [device(withPCM: false)], direction: .input))
        XCTAssertNotNil(selected.issue(in: [device(alive: nil)], direction: .input))
        XCTAssertNotNil(selected.issue(in: [device(alive: false)], direction: .input))
    }
    func testReportedStreamIndicesAreNotImplicitlyRenumbered() {
        let aggregate = device(channels: 2, startingChannel: 7)
        XCTAssertEqual(aggregate.input.physicalChannels, [7, 8])
        XCTAssertNil(EndpointSelection(uid: "chosen", lane1: 7, lane2: 8).issue(in: [aggregate], direction: .input))
        XCTAssertNotNil(EndpointSelection(uid: "chosen", lane1: 1, lane2: 2).issue(in: [aggregate], direction: .input))
    }
    func testPersistedUIDsAndChannelsSurviveRelaunch() throws {
        let suite = "AudioBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SelectionStore(defaults: defaults)
        var selection = RouteSelection()
        selection.input = EndpointSelection(uid: "chosen", lane1: 3, lane2: 4)
        selection.output = EndpointSelection(uid: "other", lane1: 1, lane2: 1)
        try store.save(selection)
        XCTAssertEqual(try SelectionStore(defaults: defaults).load(), selection)
        let text = try XCTUnwrap(defaults.data(forKey: "AudioBridge.routeSelection"))
        XCTAssertFalse(String(decoding: text, as: UTF8.self).contains("runtimeID"))
    }
    func testUnknownSchemaAndCorruptionAreNotSilentlyReset() throws {
        let suite = "AudioBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SelectionStore(defaults: defaults)
        var future = RouteSelection()
        future.schemaVersion = 99
        let data = try JSONEncoder().encode(future)
        defaults.set(data, forKey: "AudioBridge.routeSelection")
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(defaults.data(forKey: "AudioBridge.routeSelection"), data)
        let corrupt = Data("broken settings".utf8)
        defaults.set(corrupt, forKey: "AudioBridge.routeSelection")
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(defaults.data(forKey: "AudioBridge.routeSelection"), corrupt)
    }
}
