import AudioBridgeCore
import XCTest

final class BufferFrameChoiceTests: XCTestCase {
    func testCommonChoicesAreOrderedUniqueAndPowersOfTwo() {
        let choices = BufferFrameChoices.common
        XCTAssertEqual(choices, choices.sorted())
        XCTAssertEqual(Set(choices).count, choices.count)
        XCTAssertTrue(choices.allSatisfy { $0 > 0 && $0 & ($0 - 1) == 0 })
        XCTAssertEqual(choices.filter { $0 >= 100 && $0 <= 600 }, [128, 256, 512])
    }
}
