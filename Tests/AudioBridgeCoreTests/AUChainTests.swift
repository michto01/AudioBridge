import AudioBridgeAU
import AudioBridgeRealtime
import AudioToolbox
import Foundation
import XCTest

/// Deferred tests: no real plugin instantiation or hardware capture.
final class AUChainTests: XCTestCase {
    func testIdentityStateAndExplicitBypassPersist() throws {
        let identity = AUIdentity(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_PeakLimiter,
            manufacturer: kAudioUnitManufacturer_Apple)
        var chain = AUChain()
        var first = AUEffect(identity: identity, name: "Limiter")
        first.state = Data([1, 2, 3]); first.enabled = false
        chain.effects = [first, AUEffect(identity: identity, name: "Second instance")]
        try chain.validate()
        let restored = try JSONDecoder().decode(AUChain.self, from: JSONEncoder().encode(chain))
        XCTAssertEqual(restored, chain)
        XCTAssertEqual(restored.active.count, 1)
        XCTAssertEqual(restored.active[0].id, chain.effects[1].id)
    }
    func testRejectsUnknownSchemaAndDuplicateSlotIDs() {
        var chain = AUChain(); chain.schemaVersion = 2
        XCTAssertThrowsError(try chain.validate())
        chain.schemaVersion = 1
        let slot = AUEffect(identity: AUIdentity(type: kAudioUnitType_Effect,
            subtype: kAudioUnitSubType_PeakLimiter, manufacturer: kAudioUnitManufacturer_Apple), name: "Limiter")
        chain.effects = [slot, slot]
        XCTAssertThrowsError(try chain.validate())
    }
    func testSharedTransportOrderingAndZeroFill() throws {
        let name = "/abt" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(22)
        let owner = try XCTUnwrap(ABAUTransportCreate(String(name), 4))
        defer { ABAUTransportClose(owner) }
        let helper = try XCTUnwrap(ABAUTransportOpen(String(name)))
        defer { ABAUTransportClose(helper) }
        ABAUTransportUnlink(owner)
        ABAUTransportReady(helper, 0.01)
        XCTAssertTrue(ABAUTransportSnapshot(owner).ready)
        let signal: [Float] = [1, 0, 0, 0.5]
        XCTAssertEqual(signal.withUnsafeBufferPointer { ABAUCaptureWrite(owner, $0.baseAddress, 2) }, 2)
        var scratch = [Float](repeating: -1, count: 4)
        XCTAssertEqual(scratch.withUnsafeMutableBufferPointer { ABAUWorkerRead(helper, $0.baseAddress, 2) }, 2)
        XCTAssertEqual(scratch, signal)
        XCTAssertEqual(scratch.withUnsafeBufferPointer { ABAUWorkerWrite(helper, $0.baseAddress, 2) }, 2)
        var output = [Float](repeating: -1, count: 8)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { ABAUOutputRead(owner, $0.baseAddress, 4) }, 2)
        XCTAssertEqual(output, [1, 0, 0, 0.5, 0, 0, 0, 0])
        ABAUTransportFault(helper, -50)
        XCTAssertEqual(ABAUTransportSnapshot(owner).fault, -50)
        ABAUTransportShutdown(owner)
        XCTAssertTrue(ABAUTransportSnapshot(helper).stopped)
    }
}
