import XCTest
@testable import GoodreadsGUI

final class GoodreadsLookupTests: XCTestCase {

    func testExtractsIDFromARedirectedBookShowURL() {
        XCTAssertEqual(
            GoodreadsLookup.bookID(fromURL: "https://www.goodreads.com/book/show/5907-the-hobbit"),
            "5907"
        )
    }

    func testExtractsIDEvenWithoutASlug() {
        XCTAssertEqual(
            GoodreadsLookup.bookID(fromURL: "https://www.goodreads.com/book/show/12345"),
            "12345"
        )
    }

    func testExtractsIDIgnoringTrailingQueryParameters() {
        XCTAssertEqual(
            GoodreadsLookup.bookID(fromURL: "https://www.goodreads.com/book/show/42-dune?from_search=true"),
            "42"
        )
    }

    func testReturnsNilForAURLWithNoBookShowPath() {
        XCTAssertNil(GoodreadsLookup.bookID(fromURL: "https://www.goodreads.com/book/isbn/0439023483"))
        XCTAssertNil(GoodreadsLookup.bookID(fromURL: "not a url at all"))
        XCTAssertNil(GoodreadsLookup.bookID(fromURL: ""))
    }
}
