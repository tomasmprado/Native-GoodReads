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
        let books = QuoteLibrary.books(notes: notes, shelves: shelves,
                                       titles: ["2": ("Moby-Dick", "Herman Melville"), "3": ("Persuasion", "Jane Austen")])
            .filter { $0.bookID != "3" || $0.note == "just a note" }
        XCTAssertEqual(Set(books.prefix(2).map(\.title)), ["Moby-Dick", "Persuasion"], "newest first")
        XCTAssertEqual(books.last?.title, "The Fellowship of the Ring")
        XCTAssertEqual(books.first { $0.bookID == "3" }?.note, "just a note", "notes without quotes are kept too")
        XCTAssertEqual(QuoteLibrary.filter(books, "just a").map(\.bookID), ["3"], "searching finds note text")
        XCTAssertEqual(books.first { $0.bookID == "2" }?.quotes.count, 2)
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

final class GoogleFallbackTests: XCTestCase {

    private func book(_ title: String, description: String? = nil) -> Book {
        Book(id: title, title: title, author: "A", coverURL: nil, rating: nil, description: description)
    }

    func testBestMatchPrefersSameTitleWithDescription() {
        let candidates = [book("Dune Messiah", description: "x"), book("Dune"), book("Dune", description: "Spice.")]
        XCTAssertEqual(GoogleBooksClient.bestMatch(candidates, title: "Dune")?.description, "Spice.")
        XCTAssertEqual(GoogleBooksClient.bestMatch([book("Dune: Deluxe Edition")], title: "Dune")?.title, "Dune: Deluxe Edition")
        XCTAssertNil(GoogleBooksClient.bestMatch([book("Something Else")], title: "Dune"))
    }

    func testFilledKeepsWhatIsThere() {
        var mine = book("Dune")
        mine.publisher = "Mine"
        var google = book("Dune", description: "Spice.")
        google.publisher = "Theirs"
        google.pageCount = 600
        google.categories = ["Fiction / Science Fiction / General", "Fiction / General"]
        let merged = mine.filled(from: google)
        XCTAssertEqual(merged.publisher, "Mine")
        XCTAssertEqual(merged.description, "Spice.")
        XCTAssertEqual(merged.pageCount, 600)
        XCTAssertEqual(merged.genresFromCategories, ["Science Fiction", "Fiction"])
        XCTAssertEqual(mine.filled(from: nil), mine)
    }
}

final class GoogleFirstTests: XCTestCase {

    private func book(_ title: String, language: String? = nil, description: String? = nil) -> Book {
        Book(id: title, title: title, author: "A", coverURL: nil, rating: nil, language: language, description: description)
    }

    func testPrefersTheAppsLanguage() {
        let candidates = [book("Dune", language: "en", description: "Spice."), book("Dune", language: "pt-BR", description: "Especiaria.")]
        XCTAssertEqual(GoogleBooksClient.bestMatch(candidates, title: "Dune", language: "pt")?.description, "Especiaria.")
        XCTAssertEqual(GoogleBooksClient.bestMatch(candidates, title: "Dune", language: "en")?.description, "Spice.")
    }

    func testPreferringTakesGooglesDetails() {
        var mine = Book(id: "1", title: "The Hobbit", author: "J.R.R. Tolkien", coverURL: URL(string: "https://a/b.jpg"),
                        rating: nil, publisher: "Houghton", goodreadsID: "5907", description: "English.")
        mine.pageCount = 300
        var google = book("O Hobbit", language: "pt", description: "Num buraco no chão…")
        google.publisher = "Europa-América"
        let shown = mine.preferring(google)
        XCTAssertEqual(shown.title, "O Hobbit")
        XCTAssertEqual(shown.description, "Num buraco no chão…")
        XCTAssertEqual(shown.publisher, "Europa-América")
        XCTAssertEqual(shown.pageCount, 300, "kept when Google has none")
        XCTAssertEqual(shown.author, "J.R.R. Tolkien")
        XCTAssertEqual(shown.goodreadsID, "5907")
        XCTAssertEqual(shown.coverURL, mine.coverURL)
        XCTAssertEqual(mine.preferring(nil), mine)
    }

    func testGoogleDates() {
        XCTAssertEqual(BookAboutView.readableDate("2002"), "2002")
        XCTAssertNotEqual(BookAboutView.readableDate("2002-08-15"), "2002-08-15")
        XCTAssertTrue(BookAboutView.readableDate("2002-08-15").contains("2002"))
        XCTAssertEqual(BookAboutView.readableDate("soon"), "soon")
    }
}

final class ShelfTitleTests: XCTestCase {

    func testTidiesTitlesCarryingTheAuthor() {
        XCTAssertEqual(ShelfTitles.tidy("Feliz ano velho de Marcelo Rubens Paiva pela Mandarim 1996 E",
                                        author: "Marcelo Rubens Paiva"), "Feliz ano velho")
        XCTAssertEqual(ShelfTitles.tidy("Os Maias - Eça de Queirós", author: "Eça de Queirós"), "Os Maias")
        XCTAssertEqual(ShelfTitles.tidy("Conversations with Kafka by Gustav Janouch", author: "Janouch, Gustav"),
                       "Conversations with Kafka")
    }

    func testLeavesRealTitlesAlone() {
        XCTAssertEqual(ShelfTitles.tidy("Cartas de Fernando Pessoa", author: "Fernando Pessoa"), "Cartas de Fernando Pessoa")
        XCTAssertEqual(ShelfTitles.tidy("Dune (Dune, #1)", author: "Frank Herbert"), "Dune (Dune, #1)")
        XCTAssertEqual(ShelfTitles.tidy("O Evangelho segundo Jesus Cristo", author: "José Saramago"), "O Evangelho segundo Jesus Cristo")
        XCTAssertEqual(ShelfTitles.tidy("It", author: "Stephen King"), "It")
    }

    func testWithTitleKeepsEverythingElse() {
        let entry = makeEntry(id: "7", title: "Old", author: "A", rating: 4, isbn13: "9780000000001", progress: 30)
        let renamed = entry.withTitle("New")
        XCTAssertEqual(renamed.title, "New")
        XCTAssertEqual(renamed.bookID, entry.bookID)
        XCTAssertEqual(renamed.rating, 4)
        XCTAssertEqual(renamed.isbn13, "9780000000001")
        XCTAssertEqual(renamed.progress, 30)
    }
}

final class ArticleTests: XCTestCase {
    func testMovesTrailingArticleToTheFront() {
        XCTAssertEqual(ShelfTitles.frontArticle("Gato Malhado E a Andorinha Sinha, O"), "O Gato Malhado E a Andorinha Sinha")
        XCTAssertEqual(ShelfTitles.frontArticle("Great Gatsby, The"), "The Great Gatsby")
        XCTAssertEqual(ShelfTitles.frontArticle("Crime and Punishment"), "Crime and Punishment")
        XCTAssertEqual(ShelfTitles.frontArticle("Love, Actually"), "Love, Actually")
    }
}
