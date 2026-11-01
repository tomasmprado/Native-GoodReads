import XCTest
@testable import GoodreadsGUI

final class UpdateCheckerTests: XCTestCase {

    func testNewerPatchVersionIsNewer() {
        XCTAssertTrue(UpdateChecker.isNewer("1.2.1", than: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.2.0", than: "1.2.1"))
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0"))
    }

    /// Plain string comparison would sort "1.10.0" before "1.2.0" — this is
    /// exactly the bug numeric, component-wise comparison exists to avoid.
    func testDoubleDigitMinorVersionComparesNumericallyNotLexicographically() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.2.0", than: "1.10.0"))
    }

    func testExtraTrailingComponentCountsAsNewer() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
    }

    func testUnparseableCandidateIsNeverNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("not-a-version", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("", than: "1.0"))
    }
}
