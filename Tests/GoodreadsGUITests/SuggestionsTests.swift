import XCTest
@testable import GoodreadsGUI

final class SuggestionsTests: XCTestCase {

    // MARK: - parseDate

    func testParseDateFullMonthDayYear() {
        let date = Suggestions.parseDate("Aug 12, 2026")
        XCTAssertNotNil(date)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date!)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 8)
        XCTAssertEqual(c.day, 12)
    }

    func testParseDateISOFormat() {
        let date = Suggestions.parseDate("2026-08-12")
        XCTAssertNotNil(date)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date!)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 8)
        XCTAssertEqual(c.day, 12)
    }

    func testParseDateMonthYearOnly() {
        let date = Suggestions.parseDate("Aug 2026")
        XCTAssertNotNil(date)
        let c = Calendar.current.dateComponents([.year, .month], from: date!)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 8)
    }

    func testParseDateRejectsGarbage() {
        XCTAssertNil(Suggestions.parseDate("not a date"))
        XCTAssertNil(Suggestions.parseDate(""))
    }

    // MARK: - recentlyRead

    func testRecentlyReadKeepsOnlyEntriesInsideTheWindow() {
        let recent = makeEntry(id: "recent", dateRead: goodreadsDateString(daysAgo: 10))
        let old = makeEntry(id: "old", dateRead: goodreadsDateString(daysAgo: 200))
        let undated = makeEntry(id: "undated", dateRead: nil)

        let result = Suggestions.recentlyRead([recent, old, undated], withinDays: 90)

        XCTAssertEqual(result.map(\.id), ["recent"])
    }

    func testRecentlyReadWindowSizeChangesWhatQualifies() {
        let entry = makeEntry(id: "e", dateRead: goodreadsDateString(daysAgo: 5))
        XCTAssertEqual(Suggestions.recentlyRead([entry], withinDays: 30).map(\.id), ["e"])
        XCTAssertEqual(Suggestions.recentlyRead([entry], withinDays: 3).map(\.id), [])
    }

    // MARK: - looksLikeSameAuthor

    /// Both callers of this function (Goodreads' scraped author field, once
    /// `WebScripts.parseRows` flips its "Last, First" table format back, and
    /// Google Books' `authors` array) hand it "First Last" order — it isn't
    /// expected to reconcile a comma-flipped name against a plain one.
    func testLooksLikeSameAuthorMatchesOnSurnameInFirstLastOrder() {
        XCTAssertTrue(Suggestions.looksLikeSameAuthor("Agatha Christie", "AGATHA CHRISTIE"))
        XCTAssertTrue(Suggestions.looksLikeSameAuthor("j.r.r. tolkien", "J.R.R. TOLKIEN"))
    }

    func testLooksLikeSameAuthorRejectsSharedFirstNameOnly() {
        // The bug this guards against: matching on any shared token let
        // "John Smith" and "John Doe" through as the same person.
        XCTAssertFalse(Suggestions.looksLikeSameAuthor("John Smith", "John Doe"))
    }

    func testLooksLikeSameAuthorRejectsEmptyNames() {
        XCTAssertFalse(Suggestions.looksLikeSameAuthor("", "Christie, Agatha"))
        XCTAssertFalse(Suggestions.looksLikeSameAuthor("Agatha Christie", ""))
    }

    // MARK: - normalizedTitle

    func testNormalizedTitleStripsPunctuationAndCase() {
        XCTAssertEqual(Suggestions.normalizedTitle("The Hobbit!"), "the hobbit")
        XCTAssertEqual(Suggestions.normalizedTitle("Snow Crash"), "snow crash")
    }

    func testNormalizedTitleCollapsesRepeatedSeparators() {
        XCTAssertEqual(Suggestions.normalizedTitle("Foo -- Bar: A Novel"), "foo bar a novel")
    }
}
