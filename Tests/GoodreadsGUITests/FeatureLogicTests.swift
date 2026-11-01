import XCTest
@testable import GoodreadsGUI

/// A cut-down series page with the real structure (checked against
/// /series/66175 on 2026-11-01): HTML-escaped JSON in `data-react-props`.
private let seriesPageFixture = #"""
<div data-react-class="ReactComponents.SeriesList" data-react-props="{&quot;series&quot;:[{&quot;book&quot;:{&quot;bookId&quot;:&quot;7332&quot;,&quot;title&quot;:&quot;The Silmarillion&quot;,&quot;bookTitleBare&quot;:&quot;The Silmarillion&quot;,&quot;imageUrl&quot;:&quot;https://img/7332.jpg&quot;,&quot;author&quot;:{&quot;name&quot;:&quot;J.R.R. Tolkien&quot;}}},{&quot;book&quot;:{&quot;bookId&quot;:&quot;5907&quot;,&quot;title&quot;:&quot;The Hobbit&quot;,&quot;author&quot;:{&quot;name&quot;:&quot;J.R.R. Tolkien&quot;}}}],&quot;seriesHeaders&quot;:[&quot;Book 0.5&quot;,&quot;Book 1&quot;]}"></div>
<div data-react-class="ReactComponents.SeriesList" data-react-props="{&quot;series&quot;:[{&quot;book&quot;:{&quot;bookId&quot;:&quot;35736&quot;,&quot;title&quot;:&quot;Tom Bombadil&quot;}},{&quot;book&quot;:{&quot;bookId&quot;:&quot;61215351&quot;,&quot;title&quot;:&quot;The Fellowship of the Ring (The Lord of the Rings, #1)&quot;,&quot;bookTitleBare&quot;:&quot;The Fellowship of the Ring&quot;}},{&quot;book&quot;:{&quot;bookId&quot;:&quot;33&quot;,&quot;title&quot;:&quot;Box set&quot;}},{&quot;book&quot;:{&quot;bookId&quot;:&quot;5907&quot;,&quot;title&quot;:&quot;duplicate&quot;}}],&quot;seriesHeaders&quot;:[&quot;Book 1.5&quot;,&quot;Book 2&quot;,&quot;Book 1-3&quot;,&quot;Book 1&quot;]}"></div>
"""#

final class SeriesTests: XCTestCase {

    func testParsesVolumesAcrossLists() {
        let volumes = GoodreadsSeries.parse(html: seriesPageFixture)
        XCTAssertEqual(volumes.map(\.bookID), ["7332", "5907", "35736", "61215351", "33"])
        XCTAssertEqual(volumes[0].title, "The Silmarillion")
        XCTAssertEqual(volumes[0].author, "J.R.R. Tolkien")
        XCTAssertEqual(volumes[3].title, "The Fellowship of the Ring", "prefers the bare title")
        XCTAssertEqual(volumes.map(\.position), [0.5, 1, 1.5, 2, nil])
    }

    func testNextPrefersTheNextWholeNumber() {
        let volumes = GoodreadsSeries.parse(html: seriesPageFixture)
        XCTAssertEqual(GoodreadsSeries.next(after: "1", in: volumes)?.bookID, "61215351")
        XCTAssertEqual(GoodreadsSeries.next(after: "0.5", in: volumes)?.bookID, "5907")
        XCTAssertNil(GoodreadsSeries.next(after: "2", in: volumes))
        XCTAssertNil(GoodreadsSeries.next(after: "1-3", in: volumes))
        XCTAssertNil(GoodreadsSeries.next(after: nil, in: volumes))
    }

    func testPositionFromLabel() {
        XCTAssertEqual(GoodreadsSeries.position(fromLabel: "Book 4.5"), 4.5)
        XCTAssertNil(GoodreadsSeries.position(fromLabel: "Book 2 part 1/2"))
        XCTAssertNil(GoodreadsSeries.position(fromLabel: ""))
    }
}

final class ReadingPaceTests: XCTestCase {

    private let day: TimeInterval = 86400
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    func testEstimateFromTwoPoints() {
        let history = [ProgressPoint(date: start, percent: 10),
                       ProgressPoint(date: start.addingTimeInterval(10 * day), percent: 30)]
        // 2% a day, 70% left → 35 days after the last update.
        let estimate = ReadingPace.estimate(history, now: start.addingTimeInterval(10 * day))
        XCTAssertEqual(estimate?.timeIntervalSince(start) ?? 0, 45 * day, accuracy: 1)
    }

    func testOnePointUsesTheShelvingDate() {
        let history = [ProgressPoint(date: start.addingTimeInterval(5 * day), percent: 50)]
        let estimate = ReadingPace.estimate(history, startedOn: start, now: start.addingTimeInterval(5 * day))
        XCTAssertEqual(estimate?.timeIntervalSince(start) ?? 0, 10 * day, accuracy: 1)
        XCTAssertNil(ReadingPace.estimate(history), "nothing to measure from")
    }

    func testNoEstimateWhenDoneOrStalled() {
        XCTAssertNil(ReadingPace.estimate([ProgressPoint(date: start, percent: 100)], startedOn: start - day))
        let stalled = [ProgressPoint(date: start, percent: 40),
                       ProgressPoint(date: start.addingTimeInterval(3 * day), percent: 40)]
        XCTAssertNil(ReadingPace.estimate(stalled))
    }

    func testSameDayReplacesAndGoingBackStartsOver() {
        let calendar = Calendar(identifier: .gregorian)
        var history = ReadingPace.adding(ProgressPoint(date: start, percent: 10), to: [], calendar: calendar)
        history = ReadingPace.adding(ProgressPoint(date: start.addingTimeInterval(60), percent: 20), to: history, calendar: calendar)
        XCTAssertEqual(history.map(\.percent), [20])
        history = ReadingPace.adding(ProgressPoint(date: start.addingTimeInterval(2 * day), percent: 40), to: history, calendar: calendar)
        history = ReadingPace.adding(ProgressPoint(date: start.addingTimeInterval(4 * day), percent: 5), to: history, calendar: calendar)
        XCTAssertEqual(history.map(\.percent), [5])
    }

    func testReminderPercentParsing() {
        XCTAssertEqual(ReadingReminder.percent(from: "60"), 60)
        XCTAssertEqual(ReadingReminder.percent(from: " 60 % "), 60)
        XCTAssertNil(ReadingReminder.percent(from: "120"))
        XCTAssertNil(ReadingReminder.percent(from: "page 40"))
    }
}

final class ShelfFilterTests: XCTestCase {

    private let extras: [String: BookExtras] = [
        "1": BookExtras(pages: 300, genres: ["Fantasy", "Fiction"]),
        "2": BookExtras(pages: 120, genres: ["History"]),
    ]
    private let entries = [
        makeEntry(id: "1", rating: 5, dateRead: "Jan 9, 2026"),
        makeEntry(id: "2", rating: 3, dateRead: "Mar 1, 2025"),
        makeEntry(id: "3", rating: nil),
    ]

    func testRatingYearAndGenre() {
        var filters = ShelfFilters()
        XCTAssertFalse(filters.isActive)
        filters.rating = .fourUp
        XCTAssertEqual(entries.filter { filters.matches($0, extras: extras) }.map(\.id), ["1"])
        filters = ShelfFilters(rating: .unrated)
        XCTAssertEqual(entries.filter { filters.matches($0, extras: extras) }.map(\.id), ["3"])
        filters = ShelfFilters(year: 2025)
        XCTAssertEqual(entries.filter { filters.matches($0, extras: extras) }.map(\.id), ["2"])
        filters = ShelfFilters(genre: "Fantasy")
        XCTAssertEqual(entries.filter { filters.matches($0, extras: extras) }.map(\.id), ["1"])
    }

    func testMenuOptions() {
        XCTAssertEqual(ShelfFilters.years(in: entries), [2026, 2025])
        XCTAssertEqual(ShelfFilters.genres(in: entries, extras: extras), ["Fantasy", "History"])
    }

    func testQueueOrder() {
        let shelf = [makeEntry(id: "a"), makeEntry(id: "b"), makeEntry(id: "c"), makeEntry(id: "d")]
        XCTAssertEqual(QueueOrder.apply(shelf, order: ["c", "a"]).map(\.id), ["c", "a", "b", "d"])

        // Drag "d" (index 3) to the top.
        let order = QueueOrder.moved(shelf, from: IndexSet(integer: 3), to: 0, previous: ["x"])
        XCTAssertEqual(order, ["d", "a", "b", "c", "x"])
        // Drag "a" (index 0) below "c".
        XCTAssertEqual(QueueOrder.moved(shelf, from: IndexSet(integer: 0), to: 3, previous: []),
                       ["b", "c", "a", "d"])
    }

    func testLibraryMatchesAcrossShelves() {
        let dune = makeEntry(id: "1", title: "Dune", author: "Frank Herbert")
        let library: [(shelf: Shelf, entries: [ShelfEntry])] = [
            (.read, [dune, makeEntry(id: "2", title: "Emma")]),
            (Shelf.fromSlug("favourites"), [dune]),
        ]
        let matches = LibraryMatch.find("herb", in: library)
        XCTAssertEqual(matches.map(\.id), ["1"])
        XCTAssertEqual(matches.first?.shelves, ["Read", "Favourites"])
        XCTAssertTrue(LibraryMatch.find("e", in: library).isEmpty, "one letter is too little")
    }
}

final class TasteComparisonTests: XCTestCase {

    func testCommonDisagreementsAndFavourites() {
        let mine = [
            makeEntry(id: "m1", bookID: "1", title: "Dune", author: "Frank Herbert", rating: 5),
            makeEntry(id: "m2", bookID: "2", title: "Emma", author: "Jane Austen", rating: 2),
            makeEntry(id: "m3", bookID: "3", title: "Ulysses", author: "James Joyce", rating: 4),
        ]
        let wantToRead = [makeEntry(id: "w1", bookID: "9", title: "Middlemarch", author: "George Eliot")]
        let theirs = [
            // Same book, another edition: matched by title and author.
            makeEntry(id: "t1", bookID: "100", title: "Dune (Dune, #1)", author: "Herbert, Frank", rating: 4),
            makeEntry(id: "t2", bookID: "2", title: "Emma", author: "Jane Austen", rating: 5),
            makeEntry(id: "t3", bookID: "50", title: "Beloved", author: "Toni Morrison", rating: 5),
            makeEntry(id: "t4", bookID: "9", title: "Middlemarch", author: "George Eliot", rating: 5),
            makeEntry(id: "t5", bookID: "51", title: "Meh", author: "Someone", rating: 3),
        ]
        let result = TasteComparison.compute(myRead: mine, myOtherShelves: wantToRead, theirRead: theirs)
        XCTAssertEqual(Set(result.inCommon.map(\.mine.bookID)), ["1", "2"])
        XCTAssertEqual(result.disagreements.map(\.mine.bookID), ["2"])
        XCTAssertEqual(result.agreementPercent, 50)
        XCTAssertEqual(result.theirFavourites.map(\.bookID), ["50"], "not already on one of my shelves")
    }
}

final class NewReleasesTests: XCTestCase {

    func testAuthorsReadTwice() {
        let read = [makeEntry(id: "1", author: "A"), makeEntry(id: "2", author: "A"),
                    makeEntry(id: "3", author: "B"), makeEntry(id: "4", author: "C"),
                    makeEntry(id: "5", author: "C"), makeEntry(id: "6", author: "C")]
        XCTAssertEqual(NewReleases.authors(from: read), ["C", "A"])
    }

    func testIsRecent() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        XCTAssertTrue(NewReleases.isRecent("2026-03-04", now: now, calendar: calendar))
        XCTAssertTrue(NewReleases.isRecent("2027-02", now: now, calendar: calendar), "coming soon")
        XCTAssertTrue(NewReleases.isRecent("2026", now: now, calendar: calendar))
        XCTAssertFalse(NewReleases.isRecent("2024-05-01", now: now, calendar: calendar))
        XCTAssertFalse(NewReleases.isRecent("2025", now: now, calendar: calendar))
        XCTAssertFalse(NewReleases.isRecent(nil, now: now, calendar: calendar))
    }
}

final class YearSummaryTests: XCTestCase {

    func testSummary() {
        let read = [
            makeEntry(id: "1", author: "A", rating: 5, dateRead: "Jan 9, 2026"),
            makeEntry(id: "2", author: "A", rating: 3, dateRead: "Mar 1, 2026"),
            makeEntry(id: "3", author: "B", rating: 4, dateRead: "Mar 20, 2026"),
            makeEntry(id: "4", author: "B", rating: 5, dateRead: "Mar 20, 2025"),
        ]
        let extras: [String: BookExtras] = [
            "1": BookExtras(pages: 500, genres: ["Fiction", "Fantasy"]),
            "3": BookExtras(pages: 200, genres: ["Fantasy"]),
        ]
        let summary = YearSummary.compute(read: read, extras: extras, year: 2026,
                                          calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(summary.books, 3)
        XCTAssertEqual(summary.pages, 700)
        XCTAssertEqual(summary.averageRating ?? 0, 4, accuracy: 0.01)
        XCTAssertEqual(summary.topGenre, "Fantasy")
        XCTAssertEqual(summary.topAuthor, "A")
        XCTAssertEqual(summary.busiestMonth, 2)
        XCTAssertEqual(summary.longest?.id, "1")
        XCTAssertEqual(summary.favourites.map(\.id), ["1", "3"])
    }
}
