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

final class SoundtrackTests: XCTestCase {
    private func track(_ id: Int, _ artist: String, genre: String = "Pop") -> SoundtrackTrack {
        SoundtrackTrack(id: id, name: "Song \(id)", artist: artist, genre: genre, preview: nil, link: nil, artwork: nil)
    }

    func testIngredientsFromCountryEraAndGenre() {
        let portugal = AuthorCountry(code: "PT", name: "Portugal", latitude: 0, longitude: 0)
        let ingredients = Soundtrack.ingredients(country: portugal, year: 1947, genres: ["Historical Fiction", "Fiction"])
        XCTAssertEqual(ingredients.count, 3)
        XCTAssertTrue(ingredients[0].bands[1].contains("Amália Rodrigues"))
        XCTAssertTrue(ingredients[1].bands[2].contains("Glenn Miller"))
        XCTAssertTrue(Soundtrack.ingredients(country: nil, year: nil, genres: []).isEmpty)
    }

    func testSpotifyNamesDropTheExtras() {
        XCTAssertEqual(Spotify.cleanName("Verdes Anos (Instrumental) - Remastered 2003"), "Verdes Anos")
        XCTAssertEqual(Spotify.cleanName("Canção Verdes Anos [feat. Fernando Alvim]"), "Canção Verdes Anos")
        XCTAssertEqual(Spotify.cleanName("Fado"), "Fado")
    }

    func testEnergyBands() {
        XCTAssertEqual(Soundtrack.band(for: 0), 0)
        XCTAssertEqual(Soundtrack.band(for: 0.5), 1)
        XCTAssertEqual(Soundtrack.band(for: 1), 2)
        XCTAssertLessThan(Soundtrack.energy(ofGenre: "Classical"), Soundtrack.energy(ofGenre: "Hard Rock"))
    }

    func testMixTakesTurnsAndLimitsArtists() {
        let groups: [(ingredient: Int, artist: String, tracks: [SoundtrackTrack])] = [
            (0, "A", (1...10).map { track($0, "A") }),
            (1, "B", (11...20).map { track($0, "B") }),
        ]
        let mix = Soundtrack.mix(groups, energy: 0.5, seed: 7)
        XCTAssertEqual(mix.count, 4, "two per artist")
        XCTAssertEqual(Set(mix.map(\.artist)), ["A", "B"])
        XCTAssertNotEqual(mix[0].artist, mix[1].artist, "ingredients take turns")
        XCTAssertEqual(mix, Soundtrack.mix(groups, energy: 0.5, seed: 7))
        XCTAssertEqual(Soundtrack.seed("abc"), Soundtrack.seed("abc"))
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
