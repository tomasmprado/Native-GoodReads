import XCTest
@testable import GoodreadsGUI

final class ReadingLogTests: XCTestCase {
    func testKoboTimeBecomesRecordsOfWhatIsNew() {
        let book = ReaderBook(source: .kobo, sourceID: "k1", title: "Dune", author: "", isbn: nil, percent: 40,
                              finished: false, finishedOn: nil, lastOpened: Date(), secondsRead: 3600)
        let first = ReadingLog.koboRecords([book], matches: [:], previous: [:])
        XCTAssertEqual(first.records.map(\.seconds), [3600])
        XCTAssertEqual(first.totals["k1"], 3600)
        var later = book
        later.secondsRead = 4500
        let second = ReadingLog.koboRecords([later], matches: [:], previous: first.totals)
        XCTAssertEqual(second.records.map(\.seconds), [900])
        XCTAssertTrue(ReadingLog.koboRecords([later], matches: [:], previous: second.totals).records.isEmpty)
    }

    func testAppleBooksDaysAreCountedOnce() {
        let book = ReaderBook(source: .appleBooks, sourceID: "a1", title: "Os Maias", author: "", isbn: nil, percent: 10,
                              finished: false, finishedOn: nil, lastOpened: Date())
        let first = ReadingLog.appleBooksRecords([book], matches: [:], seen: [])
        XCTAssertEqual(first.records.count, 1)
        XCTAssertTrue(ReadingLog.appleBooksRecords([book], matches: [:], seen: first.seen).records.isEmpty)
    }
}

final class SeriesTrackerTests: XCTestCase {
    private func volume(_ id: String, _ number: Double?, _ title: String) -> Book {
        Book(id: id, title: title, author: "", coverURL: nil, rating: nil, seriesID: "s", seriesNumber: number)
    }

    func testNextIsTheFirstNumberedBookNotRead() {
        let volumes = [volume("3", 3, "Three"), volume("1", 1, "One"), volume("2", 2, "Two"), volume("x", nil, "Extra")]
        let progress = SeriesTracker.progress(id: "s", title: "S", volumes: volumes, readNumbers: [1], readingNumbers: [],
                                              shelvedTitles: [], wantedTitles: [])
        XCTAssertEqual(progress.volumes.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(progress.next?.id, "2")
        XCTAssertEqual(progress.read, [1])
    }

    func testABookOnYourShelvesInAnotherEditionCounts() {
        let volumes = [volume("1", 1, "One"), volume("2", 2, "Two"), volume("3", 3, "Three")]
        let progress = SeriesTracker.progress(id: "s", title: "S", volumes: volumes, readNumbers: [1], readingNumbers: [],
                                              shelvedTitles: ["two", "three"], wantedTitles: ["three"])
        XCTAssertEqual(progress.next?.id, "3")
        XCTAssertTrue(progress.nextIsWanted)
        XCTAssertEqual(progress.read, [1, 2])
    }

    func testCompleteSeries() {
        let progress = SeriesTracker.progress(id: "s", title: "S", volumes: [volume("1", 1, "One")], readNumbers: [1],
                                              readingNumbers: [], shelvedTitles: [], wantedTitles: [])
        XCTAssertTrue(progress.isComplete)
    }

    func testNewVolumesOnlyAfterTheFirstLook() {
        let now = [volume("1", 1, "One"), volume("2", 2, "Two")]
        XCTAssertTrue(SeriesTracker.newVolumes(before: nil, now: now).isEmpty)
        XCTAssertEqual(SeriesTracker.newVolumes(before: ["1"], now: now).map(\.id), ["2"])
    }

    func testBareTitle() {
        XCTAssertEqual(SeriesTracker.bareTitle("Dune (Dune, #1)"), "Dune")
    }
}

final class LovedByFriendsTests: XCTestCase {
    private func entry(_ id: String, _ title: String, _ rating: Int) -> ShelfEntry {
        var entry = ShelfEntry(id: id, bookID: id, reviewID: nil, title: title, author: "A", coverURLString: nil)
        entry.rating = rating
        return entry
    }

    func testFriendsWhoShareYourFavouritesRankHigher() {
        let mine = [entry("1", "Dune", 5), entry("2", "Emma", 5), entry("3", "Ulysses", 5)]
        let ana = Suggestions.FriendShelf(name: "Ana", read: [entry("1", "Dune", 5), entry("2", "Emma", 4), entry("10", "Hyperion", 5)])
        let rui = Suggestions.FriendShelf(name: "Rui", read: [entry("3", "Ulysses", 4), entry("11", "Solaris", 5), entry("10", "Hyperion", 5)])
        let eva = Suggestions.FriendShelf(name: "Eva", read: [entry("12", "Nada", 5)])     // shares nothing
        let picks = Suggestions.lovedByFriends(mine: mine, friends: [ana, rui, eva], shelvedIDs: ["1", "2", "3"], shelvedTitles: [])
        XCTAssertEqual(picks.map(\.book.title), ["Hyperion", "Solaris"])
        XCTAssertTrue(picks[0].reason.contains("1 more"))
    }

    func testShelvedBooksAreLeftOut() {
        let mine = [entry("1", "Dune", 5), entry("2", "Emma", 5), entry("3", "Ulysses", 5)]
        let ana = Suggestions.FriendShelf(name: "Ana", read: [entry("1", "Dune", 5), entry("10", "Hyperion", 5)])
        XCTAssertTrue(Suggestions.lovedByFriends(mine: mine, friends: [ana], shelvedIDs: ["1"], shelvedTitles: ["hyperion"]).isEmpty)
    }
}

final class StoreAndScanTests: XCTestCase {
    func testWookPrices() {
        XCTAssertEqual(WookPrices.amount(" 8,80€ "), 8.8)
        XCTAssertEqual(WookPrices.amount("1.234,50 €"), 1234.5)
        XCTAssertNil(WookPrices.amount("EM STOCK"))
        let items = WookPrices.items(from: [["title": "Os Maias", "href": "https://www.wook.pt/livro/x/1", "price": "-10% 15,90€ 14,31€"],
                                            ["title": "", "href": "https://x", "price": "1,00€"]])
        XCTAssertEqual(items.map(\.price), [15.9])
    }

    func testOnlyBookBarcodesAreTaken() {
        XCTAssertEqual(BarcodeCamera.isbn(fromBarcode: "9789722367288"), "9789722367288")
        XCTAssertNil(BarcodeCamera.isbn(fromBarcode: "9789722367289"), "bad check digit")
        XCTAssertNil(BarcodeCamera.isbn(fromBarcode: "5601234567893"), "not a book")
        XCTAssertNil(BarcodeCamera.isbn(fromBarcode: nil))
    }

    func testCountries() {
        let pt = AuthorCountry(code: "PT", name: "Portugal", latitude: 39, longitude: -8)
        let br = AuthorCountry(code: "BR", name: "Brazil", latitude: -10, longitude: -52)
        XCTAssertEqual(pt.flag, "🇵🇹")
        let tally = AuthorCountries.tally([("Eça", pt), ("Eça", pt), ("Saramago", pt), ("Amado", br), ("Unknown", nil)])
        XCTAssertEqual(tally.map(\.country.code), ["PT", "BR"])
        XCTAssertEqual(tally[0].books, 3)
        XCTAssertEqual(tally[0].authors, ["Eça", "Saramago"])
    }

    func testOldWidgetSnapshotsStillDecode() throws {
        let json = #"{"reading":[],"updated":"2026-01-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.quote())
        var withQuotes = snapshot
        withQuotes.quotes = [.init(text: "a", title: "", author: ""), .init(text: "b", title: "", author: "")]
        let today = withQuotes.quote()?.text
        let tomorrow = withQuotes.quote(on: Date().addingTimeInterval(86400))?.text
        XCTAssertNotEqual(today, tomorrow)
    }
}

final class AuthorCountriesSavedTests: XCTestCase {
    func testNeverLookedUpIsNotTheSameAsNoCountry() async {
        let name = "Nobody \(UUID().uuidString)"
        let saved = await AuthorCountries.saved(for: name)
        XCTAssertTrue(saved == nil, "an author never looked up has to be looked up")
    }
}
