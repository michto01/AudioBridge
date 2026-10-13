import AudioBridgeAU
import XCTest

final class AUEffectSearchTests: XCTestCase {
    private let listing = AUListing(id: AUIdentity(type: 1, subtype: 2, manufacturer: 3), name: "Výrobce: Stereo Compressor")

    func testEmptySearchAndPartialName() {
        XCTAssertTrue(listing.matchesSearch(""))
        XCTAssertTrue(listing.matchesSearch(" \n\t "))
        XCTAssertTrue(listing.matchesSearch("comp"))
        XCTAssertFalse(listing.matchesSearch("limiter"))
    }
    func testAllWordsMatchRegardlessOfOrderCaseOrDiacritics() {
        XCTAssertTrue(listing.matchesSearch("COMP vyrobce"))
        XCTAssertTrue(listing.matchesSearch("stereo\tVÝROBCE\ncompress"))
        XCTAssertFalse(listing.matchesSearch("vyrobce limiter"))
    }
}
