import AudioBridgeRealtime
import Foundation
import XCTest

/// Exercises transport events without HAL, plugins or real-time scheduling.
final class AUTransportWakeTests: XCTestCase {
    private enum Trigger { case capture, outputSpace, shutdown }

    func testCapturePublicationWakesOrPrecedesWait() throws { try exercise(.capture) }
    func testOutputConsumptionWakesOrPrecedesWait() throws { try exercise(.outputSpace) }
    func testShutdownReleasesWait() throws { try exercise(.shutdown) }

    private func exercise(_ trigger: Trigger) throws {
        // Repetition exercises natural publication/arm ordering, without
        // claiming exhaustive coverage of every possible fence interleaving.
        for _ in 0..<32 {
            let name = "/abw" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(22)
            let owner = try XCTUnwrap(ABAUTransportCreate(String(name), 4))
            guard let helper = ABAUTransportOpen(String(name)) else {
                ABAUTransportClose(owner); XCTFail("Cannot open test transport"); return
            }
            ABAUTransportUnlink(owner)
            let samples: [Float] = [0.25, -0.25, 0.5, -0.5, 0.75, -0.75, 1, -1]
            if trigger == .outputSpace {
                XCTAssertEqual(samples.withUnsafeBufferPointer { ABAUCaptureWrite(owner, $0.baseAddress, 4) }, 4)
                var processed = [Float](repeating: 0, count: 8)
                XCTAssertEqual(processed.withUnsafeMutableBufferPointer { ABAUWorkerRead(helper, $0.baseAddress, 4) }, 4)
                XCTAssertEqual(processed.withUnsafeBufferPointer { ABAUWorkerWrite(helper, $0.baseAddress, 4) }, 4)
                XCTAssertEqual(samples.withUnsafeBufferPointer { ABAUCaptureWrite(owner, $0.baseAddress, 2) }, 2)
            }
            let entered = DispatchSemaphore(value: 0)
            let finished = DispatchGroup()
            finished.enter()
            DispatchQueue.global().async {
                entered.signal()
                let ready = ABAUTransportWaitForBlock(helper, 2)
                XCTAssertEqual(ready, trigger != .shutdown)
                finished.leave()
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
            switch trigger {
            case .capture:
                XCTAssertEqual(samples.withUnsafeBufferPointer { ABAUCaptureWrite(owner, $0.baseAddress, 2) }, 2)
            case .outputSpace:
                var output = [Float](repeating: 0, count: 4)
                XCTAssertEqual(output.withUnsafeMutableBufferPointer { ABAUOutputRead(owner, $0.baseAddress, 2) }, 2)
            case .shutdown: ABAUTransportShutdown(owner)
            }
            let completed = finished.wait(timeout: .now() + 2)
            XCTAssertEqual(completed, .success, "Worker failed to resume")
            ABAUTransportShutdown(owner)
            guard completed == .success || finished.wait(timeout: .now() + 2) == .success else {
                // Never unmap memory that a stuck test worker could still use.
                XCTFail("Worker remained stuck after shutdown; mapping retained"); return
            }
            ABAUTransportClose(helper); ABAUTransportClose(owner)
        }
    }
}
