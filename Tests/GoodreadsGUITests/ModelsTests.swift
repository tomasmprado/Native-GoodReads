import XCTest
@testable import GoodreadsGUI

final class ShelfTests: XCTestCase {

    func testCanonicalCollapsesWantToReadIntoToRead() {
        XCTAssertEqual(Shelf.canonical("want-to-read"), "to-read")
        XCTAssertEqual(Shelf.canonical("to-read"), "to-read")
        XCTAssertEqual(Shelf.canonical("read"), "read")
    }

    func testIsPseudoShelf() {
        XCTAssertTrue(Shelf.isPseudo(""))
        XCTAssertTrue(Shelf.isPseudo("#stats"))
        XCTAssertTrue(Shelf.isPseudo("all"))
        XCTAssertTrue(Shelf.isPseudo("ALL"))
        XCTAssertFalse(Shelf.isPseudo("to-read"))
        XCTAssertFalse(Shelf.isPseudo("sci-fi"))
    }

    func testFromSlugRecognisesBuiltIns() {
        let shelf = Shelf.fromSlug("want-to-read", count: 12)
        XCTAssertEqual(shelf.name, "to-read")
        XCTAssertEqual(shelf.label, "Want to Read")
        XCTAssertEqual(shelf.count, 12)
        XCTAssertTrue(shelf.isBuiltIn)
        XCTAssertTrue(shelf.isExclusive)
    }

    func testFromSlugTitleCasesCustomShelves() {
        let shelf = Shelf.fromSlug("sci-fi-favorites")
        XCTAssertEqual(shelf.name, "sci-fi-favorites")
        XCTAssertEqual(shelf.label, "Sci Fi Favorites")
        XCTAssertFalse(shelf.isBuiltIn)
        XCTAssertFalse(shelf.isExclusive)
    }

    func testSymbolPerShelf() {
        XCTAssertEqual(Shelf.wantToRead.symbol, "bookmark")
        XCTAssertEqual(Shelf.currentlyReading.symbol, "book")
        XCTAssertEqual(Shelf.read.symbol, "checkmark.circle")
        XCTAssertEqual(Shelf.fromSlug("custom-shelf").symbol, "tag")
    }
}

final class ShelfEntryTests: XCTestCase {

    func testMatchesIsCaseInsensitiveAcrossTitleAndAuthor() {
        let entry = makeEntry(title: "The Hobbit", author: "J.R.R. Tolkien")
        XCTAssertTrue(entry.matches(""))
        XCTAssertTrue(entry.matches("hobbit"))
        XCTAssertTrue(entry.matches("TOLKIEN"))
        XCTAssertFalse(entry.matches("dune"))
    }

    /// Guards the exact risk of adding new `Optional` fields (`dateAdded`,
    /// `isbn`, `isbn13`) to a `Codable` struct that's already cached to disk
    /// under the old shape — a cache file written by an earlier build must
    /// still decode cleanly, with the new fields simply absent.
    func testDecodesOldCacheFormatMissingNewerFields() throws {
        let json = """
        {
          "id": "r1",
          "bookID": "123",
          "reviewID": "r1",
          "title": "The Hobbit",
          "author": "J.R.R. Tolkien",
          "coverURLString": null,
          "rating": 5,
          "dateRead": "Aug 12, 2020",
          "progress": null
        }
        """
        let entry = try JSONDecoder().decode(ShelfEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.bookID, "123")
        XCTAssertEqual(entry.rating, 5)
        XCTAssertNil(entry.dateAdded)
        XCTAssertNil(entry.isbn)
        XCTAssertNil(entry.isbn13)
    }
}

final class ShelfSortOrderTests: XCTestCase {

    func testAsShelvedPreservesOriginalOrder() {
        let a = makeEntry(id: "a")
        let b = makeEntry(id: "b")
        XCTAssertEqual(ShelfSortOrder.asShelved.sorted([b, a]).map(\.id), ["b", "a"])
    }

    func testTitleSortIsCaseInsensitive() {
        let a = makeEntry(id: "a", title: "banana")
        let b = makeEntry(id: "b", title: "Apple")
        XCTAssertEqual(ShelfSortOrder.title.sorted([a, b]).map(\.id), ["b", "a"])
    }

    func testAuthorSortIsCaseInsensitive() {
        let a = makeEntry(id: "a", author: "zeta")
        let b = makeEntry(id: "b", author: "Alpha")
        XCTAssertEqual(ShelfSortOrder.author.sorted([a, b]).map(\.id), ["b", "a"])
    }

    func testRatingSortPutsUnratedLast() {
        let unrated = makeEntry(id: "unrated", rating: nil)
        let three = makeEntry(id: "three", rating: 3)
        let five = makeEntry(id: "five", rating: 5)
        XCTAssertEqual(
            ShelfSortOrder.rating.sorted([three, unrated, five]).map(\.id),
            ["five", "three", "unrated"]
        )
    }

    func testDateReadSortNewestFirstWithUndatedLast() {
        let newer = makeEntry(id: "newer", dateRead: goodreadsDateString(daysAgo: 1))
        let older = makeEntry(id: "older", dateRead: goodreadsDateString(daysAgo: 100))
        let undated = makeEntry(id: "undated", dateRead: nil)
        XCTAssertEqual(
            ShelfSortOrder.dateRead.sorted([older, undated, newer]).map(\.id),
            ["newer", "older", "undated"]
        )
    }
}
