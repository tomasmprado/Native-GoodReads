import XCTest
@testable import GoodreadsGUI

final class BingoTests: XCTestCase {
    private func facts(_ id: String, pages: Int? = nil, year: Int? = nil, country: String? = nil,
                       genres: [String] = [], ratings: Int? = nil, read: String = "Mar 3, 2025") -> BingoFacts {
        var book = BingoFacts(bookID: id, title: id, author: "A\(id)", cover: nil, dateRead: Suggestions.parseDate(read))
        book.pages = pages
        book.published = year
        book.countryCode = country
        book.genres = genres
        book.ratingsCount = ratings
        return book
    }

    func testSquaresMatchWhatTheBookSays() {
        let book = facts("1", pages: 700, year: 1890, country: "NG", genres: ["Poetry", "Classics"], ratings: 400)
        XCTAssertEqual(Bingo.matches(.longerThan(500), book), true)
        XCTAssertEqual(Bingo.matches(.shorterThan(150), book), false)
        XCTAssertEqual(Bingo.matches(.olderThan(1900), book), true)
        XCTAssertEqual(Bingo.matches(.continent("AF"), book), true)
        XCTAssertEqual(Bingo.matches(.genre("Poetry"), book), true)
        XCTAssertEqual(Bingo.matches(.obscure(1000), book), true)
        XCTAssertNil(Bingo.matches(.lowRated(3.6), book), "no rating known")
        XCTAssertEqual(Bingo.matches(.genre("Mystery"), facts("2", genres: ["Crime"])), true, "aliases count")
        XCTAssertEqual(Bingo.matches(.recent, facts("3", year: 2024, read: "Mar 3, 2025")), true)
    }

    func testContinents() {
        XCTAssertEqual(Bingo.continent(of: "pt"), "EU")
        XCTAssertEqual(Bingo.continent(of: "BR"), "SA")
        XCTAssertEqual(Bingo.continent(of: "JP"), "AS")
        XCTAssertEqual(Bingo.continent(of: "CV"), "AF")
    }

    func testCardComesFromYourGaps() {
        // Lots of European novels of 300 pages; no poetry, nothing old.
        let past = (0..<30).map { facts("\($0)", pages: 300, year: 2000, country: "PT", genres: ["Fiction"], ratings: 50_000) }
        let card = Bingo.makeCard(year: 2026, past: past, passedGenres: [("Horror", 5)],
                                  hasInfluences: true, hasSeries: false, seed: 1)
        XCTAssertEqual(card.squares.count, 16)
        XCTAssertEqual(Set(card.squares).count, 16, "no square twice")
        XCTAssertTrue(card.squares.contains(.fromDiscover))
        XCTAssertTrue(card.squares.contains(.passedGenre("Horror", 5)))
        XCTAssertFalse(card.squares.contains(.genre("Horror")))
        XCTAssertFalse(card.squares.contains(.seriesNext))
        XCTAssertLessThanOrEqual(card.squares.filter { $0.family == "genre" }.count, 4)
        XCTAssertLessThanOrEqual(card.squares.filter { $0.family == "continent" }.count, 2)
        XCTAssertEqual(card, Bingo.makeCard(year: 2026, past: past, passedGenres: [("Horror", 5)],
                                            hasInfluences: true, hasSeries: false, seed: 1), "same seed, same card")
    }

    func testLines() {
        XCTAssertEqual(Bingo.lines(done: [0, 1, 2]), [])
        XCTAssertEqual(Bingo.lines(done: [0, 1, 2, 3]), [[0, 1, 2, 3]])
        XCTAssertEqual(Bingo.lines(done: [0, 5, 10, 15]), [[0, 5, 10, 15]])
        XCTAssertEqual(Bingo.lines(done: [3, 6, 9, 12, 7, 11, 15]), [[3, 7, 11, 15], [3, 6, 9, 12]])
    }
}

final class OnThisDayTests: XCTestCase {
    private func read(_ title: String, _ date: String) -> ShelfEntry {
        var entry = ShelfEntry(id: title, bookID: title, reviewID: nil, title: title, author: "X", coverURLString: nil)
        entry.dateRead = date
        return entry
    }

    func testFindsFinishedAndInProgressBooks() {
        let today = Suggestions.parseDate("Nov 5, 2026")!
        let days = OnThisDay.find(in: [read("Finished", "Nov 6, 2023"), read("Reading", "Nov 20, 2023"),
                                       read("Too far", "Jan 2, 2023"), read("No day", "Nov 2023"),
                                       read("This year", "Nov 5, 2026")], today: today)
        XCTAssertEqual(days.map(\.year), [2023])
        XCTAssertEqual(days.first?.finished.map(\.title), ["Finished"])
        XCTAssertEqual(days.first?.reading.map(\.title), ["Reading"])
    }
}

final class BookshelfTests: XCTestCase {
    func testRowsFitTheWidth() {
        XCTAssertEqual(Bookshelf.rows(widths: [30, 30, 30], available: 100, spacing: 3), [0..<3])
        XCTAssertEqual(Bookshelf.rows(widths: [30, 30, 30, 30], available: 100, spacing: 3), [0..<3, 3..<4])
        XCTAssertEqual(Bookshelf.rows(widths: [120, 20], available: 100, spacing: 3), [0..<1, 1..<2], "too wide still gets a row")
        XCTAssertEqual(Bookshelf.rows(widths: [], available: 100, spacing: 3), [])
    }

    func testSpines() {
        XCTAssertLessThan(Bookshelf.spineWidth(pages: 120), Bookshelf.spineWidth(pages: 900))
        XCTAssertEqual(Bookshelf.spineWidth(pages: 5000), 54)
        XCTAssertEqual(Bookshelf.spineHeight("42"), Bookshelf.spineHeight("42"))
        XCTAssertEqual(Bookshelf.surname("José Saramago"), "Saramago")
        XCTAssertEqual(Bookshelf.surname("Sophia de Mello Breyner Andresen"), "Andresen")
        XCTAssertEqual(Bookshelf.surname("Ludwig van Beethoven"), "van Beethoven")
        XCTAssertEqual(Bookshelf.surname("Homer"), "Homer")
    }
}

final class InfluenceSuggestionTests: XCTestCase {
    func testInfluencesCountAndExplainThemselves() {
        let book = Book(id: "k1", title: "The Trial", author: "Franz Kafka", coverURL: nil, rating: nil, isbn: nil)
        let picks = Recommender.rank([Candidate(book: book, sources: [.influence("Franz Kafka", shaped: ["José Saramago", "Jorge Luis Borges"])])],
                                     profile: TasteProfile(), excluded: [])
        XCTAssertEqual(picks.first?.book.title, "The Trial")
        XCTAssertTrue(picks.first?.reason.contains("José Saramago") ?? false)
    }
}

final class InfluenceMapTests: XCTestCase {
    func testDiscoveriesAndBridges() {
        let yours: [String: AuthorInfluences.Resolved] = [
            "José Saramago": .init(id: "Q1", influencedBy: ["Q9", "Q2"]),
            "Jorge Luis Borges": .init(id: "Q2", influencedBy: ["Q9"]),
            "Haruki Murakami": .init(id: "Q3", influencedBy: ["Q9", "Q8"]),
        ]
        let people: [String: InfluencePerson] = [
            "Q9": .init(id: "Q9", name: "Franz Kafka", about: nil),
            "Q8": .init(id: "Q8", name: "Raymond Chandler", about: nil),
            "Q2": .init(id: "Q2", name: "Jorge Luis Borges", about: nil),
        ]
        let (discoveries, bridges) = AuthorInfluences.map(yours: yours, people: people)
        XCTAssertEqual(discoveries.first?.person.name, "Franz Kafka")
        XCTAssertEqual(discoveries.first?.influencedYours.count, 3)
        XCTAssertEqual(discoveries.map(\.person.name), ["Franz Kafka", "Raymond Chandler"])
        XCTAssertEqual(bridges, [AuthorInfluences.Bridge(from: "Jorge Luis Borges", to: "José Saramago")])
    }
}
