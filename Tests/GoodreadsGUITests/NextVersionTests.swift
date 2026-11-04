import XCTest
@testable import GoodreadsGUI

final class ReadingLogTests: XCTestCase {
    private func record(_ book: String?, minutes: Int, from: Int?, to: Int?, source: ReadingRecord.Source = .timer) -> ReadingRecord {
        ReadingRecord(bookID: book, title: "T", start: Date(), seconds: minutes * 60, startPage: from, endPage: to, source: source)
    }

    func testPagesPerHourPrefersTheBookItself() {
        let records = [record("a", minutes: 30, from: 10, to: 40),      // 60 an hour
                       record("b", minutes: 60, from: 0, to: 20)]       // 20 an hour
        XCTAssertEqual(ReadingLog.pagesPerHour(records, bookID: "a") ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(ReadingLog.pagesPerHour(records, bookID: "c") ?? 0, 50 / 1.5, accuracy: 0.01, "falls back to every book")
        XCTAssertNil(ReadingLog.pagesPerHour([record("a", minutes: 10, from: 0, to: 10)]), "under 20 minutes is too little")
        XCTAssertNil(ReadingLog.pagesPerHour([record("a", minutes: 60, from: 0, to: 10, source: .kobo)]), "only timed sessions")
    }

    func testTimeLeft() {
        XCTAssertEqual(ReadingLog.timeLeft(pagesLeft: 90, pagesPerHour: 30), 3 * 3600)
        XCTAssertNil(ReadingLog.timeLeft(pagesLeft: 0, pagesPerHour: 30))
    }

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
    private func volume(_ id: String, _ position: Double?, _ title: String) -> GoodreadsSeries.Volume {
        GoodreadsSeries.Volume(bookID: id, title: title, author: "", coverURL: nil,
                               label: position.map { "Book \($0.formatted())" } ?? "Book 1-3", position: position)
    }

    func testNextIsTheFirstNumberedBookNotRead() {
        let volumes = [volume("1", 1, "One"), volume("15", 1.5, "Novella"), volume("2", 2, "Two"),
                       volume("3", 3, "Three"), volume("box", nil, "Box set")]
        let progress = SeriesTracker.progress(title: "S", url: URL(string: "https://x/s")!, volumes: volumes,
                                              readPositions: [1], readingPositions: [], shelvedIDs: [], shelvedTitles: [],
                                              wantedIDs: [], wantedTitles: [])
        XCTAssertEqual(progress.volumes.map(\.bookID), ["1", "2", "3"])
        XCTAssertEqual(progress.next?.bookID, "2")
        XCTAssertFalse(progress.nextIsWanted)
    }

    func testABookReadInAnotherEditionCounts() {
        let volumes = [volume("1", 1, "One"), volume("2", 2, "Two"), volume("3", 3, "Three")]
        let progress = SeriesTracker.progress(title: "S", url: URL(string: "https://x/s")!, volumes: volumes,
                                              readPositions: [1], readingPositions: [], shelvedIDs: ["other"],
                                              shelvedTitles: ["two"], wantedIDs: ["3"], wantedTitles: [])
        XCTAssertEqual(progress.next?.bookID, "3")
        XCTAssertTrue(progress.nextIsWanted)
    }

    func testCompleteSeries() {
        let progress = SeriesTracker.progress(title: "S", url: URL(string: "https://x/s")!, volumes: [volume("1", 1, "One")],
                                              readPositions: [1], readingPositions: [], shelvedIDs: [], shelvedTitles: [],
                                              wantedIDs: [], wantedTitles: [])
        XCTAssertTrue(progress.isComplete)
    }

    func testNewVolumesOnlyAfterTheFirstLook() {
        let now = [volume("1", 1, "One"), volume("2", 2, "Two")]
        XCTAssertTrue(SeriesTracker.newVolumes(before: nil, now: now).isEmpty)
        XCTAssertEqual(SeriesTracker.newVolumes(before: ["1"], now: now).map(\.bookID), ["2"])
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
