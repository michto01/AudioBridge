import XCTest
@testable import AudioBridgeCore

final class ShellStatusTests: XCTestCase {
    func testShellCannotClaimWorkingAudio() {
        let status = ShellStatus()
        XCTAssertEqual(status.title, "Unconfigured")
        XCTAssertEqual(status.detail, "Audio routing is not yet implemented.")
        XCTAssertEqual(status.meterText, "Unavailable")
        XCTAssertFalse(status.canStartRouting)
    }
}
