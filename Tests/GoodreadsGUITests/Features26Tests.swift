import XCTest
@testable import GoodreadsGUI

final class PagesTests: XCTestCase {

    func testPageFromPercentAndPace() throws {
        let day: TimeInterval = 86400
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let history = [ProgressPoint(date: start, percent: 10), ProgressPoint(date: start + 10 * day, percent: 60)]
        let pages = try XCTUnwrap(ReadingPace.pages(percent: 60, total: 400, history: history))
        XCTAssertEqual(pages.page, 240)
        XCTAssertEqual(pages.left, 160)
        XCTAssertEqual(try XCTUnwrap(pages.perDay), 20, accuracy: 0.001, "50% of 400 pages in 10 days")
    }

    func testNoPaceWithoutHistory() {
        XCTAssertNil(ReadingPace.pages(percent: 30, total: 300, history: [])?.perDay)
        XCTAssertNil(ReadingPace.pages(percent: 30, total: 0, history: []))
    }
}

final class SmartListTests: XCTestCase {

    private let extras: [String: BookExtras] = [
        "1": BookExtras(pages: 180, genres: [], rating: 4.4),
        "2": BookExtras(pages: 600, genres: [], rating: 3.8),
        "3": BookExtras(pages: 240, genres: [], rating: nil),
    ]
    private lazy var entries = [
        makeEntry(id: "1", author: "Ursula K. Le Guin", dateAdded: "Mar 1, 2024"),
        makeEntry(id: "2", author: "Someone", dateAdded: "Jan 5, 2020"),
        makeEntry(id: "3", author: "Le Guin, Ursula K.", dateAdded: "Jun 2, 2025"),
        makeEntry(id: "4", author: "Nobody"),
    ]

    func testShortBooks() {
        var filters = ShelfFilters()
        filters.smart = .short
        XCTAssertEqual(entries.filter { filters.matches($0, extras: extras) }.map(\.id), ["1", "3"])
        XCTAssertEqual(filters.ordered(entries.filter { filters.matches($0, extras: extras) }, extras: extras)?.map(\.id), ["1", "3"])
    }

    func testHighestRatedOnlyKnownAndSorted() {
        var filters = ShelfFilters()
        filters.smart = .highlyRated
        XCTAssertEqual(entries.filter { filters.matches($0, extras: extras) }.map(\.id), ["1"])
    }

    func testWaitingLongestOrder() {
        var filters = ShelfFilters()
        filters.smart = .waitingLongest
        XCTAssertEqual(filters.ordered(entries, extras: extras)?.map(\.id), ["2", "1", "3", "4"],
                       "oldest first; books without a date last")
    }

    func testFavouriteAuthors() {
        let read = [
            makeEntry(id: "a", author: "Ursula K. Le Guin", rating: 5),
            makeEntry(id: "b", author: "Le Guin, Ursula K.", rating: 4),
            makeEntry(id: "c", author: "Once Only", rating: 5),
        ]
        let loved = ShelfFilters.favouriteAuthors(in: read)
        var filters = ShelfFilters()
        filters.smart = .favouriteAuthors
        XCTAssertEqual(entries.filter { filters.matches($0, extras: extras, favouriteAuthors: loved) }.map(\.id), ["1", "3"])
        XCTAssertFalse(loved.contains(ShelfFilters.authorKey("Once Only")))
    }
}

final class StoreLinksTests: XCTestCase {

    func testPortugalGetsLocalShops() {
        let links = StoreLinks.links(title: "Ensaio sobre a Cegueira", author: "José Saramago", region: "PT")
        XCTAssertEqual(links.first?.name, "Wook")
        XCTAssertTrue(links.contains { $0.url.host == "www.amazon.es" })
        XCTAssertTrue(links.contains { $0.url.host == "www.bertrand.pt" })
        XCTAssertEqual(links.first?.url.absoluteString,
                       "https://www.wook.pt/pesquisa?keyword=Ensaio%20sobre%20a%20Cegueira%20Jos%C3%A9%20Saramago")
    }

    func testElsewhere() {
        let links = StoreLinks.links(title: "Dune & Co", author: "", region: "US")
        XCTAssertFalse(links.contains { $0.name == "Wook" })
        XCTAssertTrue(links.contains { $0.url.host == "www.amazon.com" })
        XCTAssertTrue(links.allSatisfy { !$0.url.absoluteString.contains("Dune & Co") }, "the query is encoded")
        XCTAssertTrue(StoreLinks.links(title: "", author: "", region: "US").isEmpty)
    }
}

final class QuoteLibraryTests: XCTestCase {

    func testNamesSortsAndSearches() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let notes = [
            "1": BookNote(text: "", quotes: ["All we have to decide is what to do with the time"], updated: older),
            "2": BookNote(text: "", quotes: ["Call me Ishmael.", "It is not down on any map"], updated: newer),
            "3": BookNote(text: "just a note", quotes: [], updated: newer),
        ]
        let shelves = [makeEntry(id: "1", title: "The Fellowship of the Ring", author: "J.R.R. Tolkien")]
        let books = QuoteLibrary.books(notes: notes, shelves: shelves, titles: ["2": ("Moby-Dick", "Herman Melville")])
        XCTAssertEqual(books.map(\.title), ["Moby-Dick", "The Fellowship of the Ring"], "newest first, notes without quotes left out")
        XCTAssertEqual(books.first?.quotes.count, 2)
        XCTAssertEqual(QuoteLibrary.filter(books, "map").flatMap(\.quotes).map(\.text), ["It is not down on any map"])
        XCTAssertEqual(QuoteLibrary.filter(books, "tolkien").first?.quotes.count, 1, "matching the author keeps all its quotes")
    }
}

final class TextSizeTests: XCTestCase {

    func testSystemSizesScale() {
        XCTAssertEqual(TextZoom.systemFactor(.large), 1)
        XCTAssertLessThan(TextZoom.systemFactor(.small), 1)
        XCTAssertGreaterThan(TextZoom.systemFactor(.xxLarge), TextZoom.systemFactor(.xLarge))
        XCTAssertGreaterThan(TextZoom.systemFactor(.accessibility1), TextZoom.systemFactor(.xxxLarge))
    }
}
