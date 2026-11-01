import XCTest
@testable import GoodreadsGUI

final class BookLanguageTests: XCTestCase {

    func testAnyMatchesEverythingIncludingNil() {
        XCTAssertTrue(BookLanguage.any.matches("french"))
        XCTAssertTrue(BookLanguage.any.matches(nil))
        XCTAssertTrue(BookLanguage.any.matches(""))
    }

    func testExactAndAbbreviatedCodesMatch() {
        XCTAssertTrue(BookLanguage.english.matches("en"))
        XCTAssertTrue(BookLanguage.english.matches("eng"))
        XCTAssertTrue(BookLanguage.english.matches("English"))
        XCTAssertFalse(BookLanguage.english.matches("French"))
    }

    func testNilOrEmptyReportedLanguageNeverMatchesASpecificLanguage() {
        XCTAssertFalse(BookLanguage.english.matches(nil))
        XCTAssertFalse(BookLanguage.english.matches(""))
    }

    /// Goodreads reports some editions as "Spanish; Castilian" — a code
    /// match anywhere in the tokenized string counts, not just an exact one.
    func testMatchesWithinACompoundLanguageString() {
        XCTAssertTrue(BookLanguage.spanish.matches("Spanish; Castilian"))
    }

    func testRestrictCodeIsNilForAnyAndTheFirstCodeOtherwise() {
        XCTAssertNil(BookLanguage.any.restrictCode)
        XCTAssertEqual(BookLanguage.english.restrictCode, "en")
        XCTAssertEqual(BookLanguage.portuguese.restrictCode, "pt")
    }
}
