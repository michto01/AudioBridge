import AudioBridgeAU
import AudioBridgeRealtime
import AudioToolbox
import Foundation
import XCTest

/// Deferred tests: no real plugin instantiation or hardware capture.
final class AUChainTests: XCTestCase {
    func testCatalogCacheRoundTripIncludingEmptyCatalog() throws {
        let empty = AUCatalogCache(effects: [], scannedAt: Date(timeIntervalSince1970: 100))
        let restored = try JSONDecoder().decode(AUCatalogCache.self, from: JSONEncoder().encode(empty))
        try restored.validate()
        XCTAssertEqual(restored.effects.count, 0)
        XCTAssertEqual(restored.scannedAt, empty.scannedAt)
        let identity = AUIdentity(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_PeakLimiter, manufacturer: kAudioUnitManufacturer_Apple)
        // Decode public listing data without instantiating an Audio Unit.
        let listingData = try JSONSerialization.data(withJSONObject: ["id": ["type": identity.type, "subtype": identity.subtype, "manufacturer": identity.manufacturer], "name": "Limiter"])
        let listing = try JSONDecoder().decode(AUListing.self, from: listingData)
        XCTAssertThrowsError(try AUCatalogCache(effects: [listing, listing]).validate())
    }
    func testSmallerBlocksRespectStartupFillAndRejectZero() throws {
        XCTAssertEqual(try AUBlockSizing.frames(startupFill: 16), 16)
        XCTAssertEqual(try AUBlockSizing.frames(startupFill: 32), 32)
        XCTAssertEqual(try AUBlockSizing.frames(startupFill: 48), 32)
        XCTAssertEqual(try AUBlockSizing.frames(startupFill: 128), 128)
        XCTAssertEqual(try AUBlockSizing.frames(startupFill: 512), 256)
        XCTAssertThrowsError(try AUBlockSizing.frames(startupFill: 0))
        XCTAssertThrowsError(try AUBlockSizing.frames(startupFill: 32769))
    }
    func testLiveCommandIdentityAndWholeChainBypass() throws {
        let command = AULiveCommand(bypass: true)
        let restored = try JSONDecoder().decode(AULiveCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(restored.id, command.id)
        XCTAssertEqual(restored.bypass, true)
        XCTAssertNil(restored.edit)
        XCTAssertNil(restored.chain)
    }
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
        ABAUTransportSetBypass(owner, true)
        XCTAssertTrue(ABAUTransportBypassed(helper))
        ABAUTransportSetBypass(owner, false)
        XCTAssertFalse(ABAUTransportBypassed(helper))
        XCTAssertTrue(ABAUTransportSnapshot(owner).ready)
        let signal: [Float] = [1, 0, 0, 0.5]
        XCTAssertEqual(signal.withUnsafeBufferPointer { ABAUCaptureWrite(owner, $0.baseAddress, 2) }, 2)
        var scratch = [Float](repeating: -1, count: 4)
        XCTAssertEqual(scratch.withUnsafeMutableBufferPointer { ABAUWorkerRead(helper, $0.baseAddress, 2) }, 2)
        XCTAssertEqual(scratch, signal)
        XCTAssertEqual(scratch.withUnsafeBufferPointer { ABAUWorkerWrite(helper, $0.baseAddress, 2) }, 2)
        XCTAssertEqual(ABAUTransportProcessedFrames(owner), 2)
        XCTAssertEqual(ABAUTransportQueues(owner).inputFrames, 0)
        XCTAssertEqual(ABAUTransportQueues(owner).outputFrames, 2)
        var output = [Float](repeating: -1, count: 8)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { ABAUOutputRead(owner, $0.baseAddress, 4) }, 2)
        XCTAssertEqual(output, [1, 0, 0, 0.5, 0, 0, 0, 0])
        ABAUTransportFault(helper, -50)
        XCTAssertEqual(ABAUTransportSnapshot(owner).fault, -50)
        ABAUTransportShutdown(owner)
        XCTAssertTrue(ABAUTransportSnapshot(helper).stopped)
        XCTAssertTrue(ABAUTransportStopped(helper))
    }
    func testTimingAccountingWithoutSleepingOrRendering() throws {
        let name = "/abt" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(22)
        let owner = try XCTUnwrap(ABAUTransportCreate(String(name), 1024))
        defer { ABAUTransportClose(owner) }
        let helper = try XCTUnwrap(ABAUTransportOpen(String(name)))
        defer { ABAUTransportClose(helper) }
        ABAUTransportUnlink(owner)
        ABAUTransportConfigureTiming(helper, 1_000_000)
        for duration in [UInt64(500_000), 1_000_000, 1_000_001] {
            ABAUTransportRecordRenderDuration(helper, duration)
        }
        ABAUTransportRecordWorkerWait(helper, 100_000, 50_000) // Early return: no underflow.
        ABAUTransportRecordWorkerWait(helper, 100_000, 1_100_000) // Equal budget is not over it.
        ABAUTransportRecordWorkerWait(helper, 100_000, 1_100_001)
        let timing = ABAUTransportSnapshot(owner)
        XCTAssertEqual(timing.renderBlocks, 3)
        XCTAssertEqual(timing.renderNanoseconds, 2_500_001)
        XCTAssertEqual(timing.lastRenderNanoseconds, 1_000_001)
        XCTAssertEqual(timing.maxRenderNanoseconds, 1_000_001)
        XCTAssertEqual(timing.blockBudgetNanoseconds, 1_000_000)
        XCTAssertEqual(timing.renderOverBudgetBlocks, 1)
        XCTAssertEqual(timing.workerWaits, 3)
        XCTAssertEqual(timing.workerLateWakeups, 1)
        XCTAssertEqual(timing.maxWorkerWakeLatenessNanoseconds, 1_000_001)
        ABAUTransportConfigureTiming(helper, 0) // Unknown duration disables classification.
        ABAUTransportRecordRenderDuration(helper, 2_000_000)
        ABAUTransportRecordWorkerWait(helper, 0, 2_000_000)
        XCTAssertEqual(ABAUTransportSnapshot(owner).renderOverBudgetBlocks, 1)
        XCTAssertEqual(ABAUTransportSnapshot(owner).workerLateWakeups, 1)
    }
}
