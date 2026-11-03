import XCTest
@testable import GoodreadsGUI

final class CustomStoreTests: XCTestCase {
    func testFillsPlaceholders() {
        let wook = CustomStore(name: "Wook", template: "https://www.wook.pt/pesquisa?keyword={bookname}")
        XCTAssertEqual(wook.url(title: "Os Maias", author: "Eça", isbn: nil)?.absoluteString,
                       "https://www.wook.pt/pesquisa?keyword=Os%20Maias")
        let byISBN = CustomStore(name: "Lib", template: "https://lib.example/find?isbn={isbn}&a={author}")
        XCTAssertEqual(byISBN.url(title: "T", author: "A & B", isbn: "9789722367288")?.absoluteString,
                       "https://lib.example/find?isbn=9789722367288&a=A%20%26%20B")
        XCTAssertTrue(wook.isValid)
        XCTAssertFalse(CustomStore(name: "", template: wook.template).isValid)
        XCTAssertFalse(CustomStore(name: "X", template: "https://no-placeholder.example").isValid)
        XCTAssertFalse(CustomStore(name: "X", template: "javascript:{title}").isValid)
    }
}

final class FinishPlanTests: XCTestCase {
    func testPagesPerDay() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 10))!
        let in9Days = calendar.date(byAdding: .day, value: 9, to: now)!
        XCTAssertEqual(FinishPlans.pagesPerDay(left: 100, by: in9Days, now: now, calendar: calendar), 10, "10 days counting today")
        XCTAssertEqual(FinishPlans.pagesPerDay(left: 0, by: in9Days, now: now, calendar: calendar), 0)
        XCTAssertEqual(FinishPlans.pagesPerDay(left: 5, by: now, now: now, calendar: calendar), 5, "due today")
        XCTAssertNil(FinishPlans.pagesPerDay(left: 5, by: calendar.date(byAdding: .day, value: -2, to: now)!, now: now, calendar: calendar))
    }
}

final class WeekSummaryTests: XCTestCase {
    func testPagesStreakAndMonth() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 20))!
        func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: 12))! }
        let history = ["1": [ProgressPoint(date: day(1), percent: 10), ProgressPoint(date: day(8), percent: 30),
                             ProgressPoint(date: day(9), percent: 40), ProgressPoint(date: day(10), percent: 50)]]
        let read = [makeEntry(id: "r1", dateRead: "Nov 02, 2026"), makeEntry(id: "r2", dateRead: "Oct 30, 2026")]
        let summary = WeekSummary.compute(history: history, pages: ["1": 200], read: read, now: now, calendar: calendar)
        XCTAssertEqual(summary.pages, 80, "10% → 50% of 200 pages this week")
        XCTAssertEqual(summary.streak, 3, "8, 9 and 10 November")
        XCTAssertEqual(summary.finishedThisMonth, 1)
    }
}

final class YearWrapTests: XCTestCase {
    func testWorksOutTheYear() {
        let read = [
            makeEntry(id: "1", title: "Short", author: "A", rating: 5, dateRead: "Jan 10, 2025"),
            makeEntry(id: "2", title: "Long", author: "A", rating: 3, dateRead: "Mar 02, 2025"),
            makeEntry(id: "3", title: "Mid", author: "B", rating: 4, dateRead: "Mar 20, 2025"),
            makeEntry(id: "4", title: "Other year", author: "C", rating: 5, dateRead: "Mar 20, 2024"),
        ]
        let extras: [String: BookExtras] = [
            "1": BookExtras(pages: 40, genres: ["Fantasy"], rating: 4.5, ratingsCount: 3),
            "2": BookExtras(pages: 848, genres: ["Fantasy", "Classics"], rating: 3.9, ratingsCount: 6_267_103),
            "3": BookExtras(pages: 250, genres: ["Classics"], rating: 4.1, ratingsCount: 900),
        ]
        let wrap = YearWrap.compute(read: read, extras: extras, year: 2025)
        XCTAssertEqual(wrap.books.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(wrap.pages, 1138)
        XCTAssertEqual(wrap.shortest?.entry.id, "1")
        XCTAssertEqual(wrap.longest?.value, 848)
        XCTAssertEqual(wrap.averageLength, 379)
        XCTAssertEqual(wrap.mostShelved?.entry.id, "2")
        XCTAssertEqual(wrap.leastShelved?.entry.id, "1")
        XCTAssertEqual(wrap.highestRated?.entry.id, "1")
        XCTAssertEqual(wrap.myAverage, 4)
        XCTAssertEqual(wrap.topAuthor?.name, "A")
        XCTAssertEqual(wrap.busiestMonth, 2, "March")
        XCTAssertEqual(wrap.first?.id, "1")
        XCTAssertEqual(wrap.last?.id, "3")
        XCTAssertEqual(wrap.fiveStars.map(\.id), ["1"])
        XCTAssertEqual(Set(wrap.topGenres), ["Fantasy", "Classics"])
    }
}

final class ShareIntakeTests: XCTestCase {
    func testFindsISBNs() {
        XCTAssertEqual(ShareIntake.isbn(in: #"<meta property="books:isbn" content="9789722367288">"#), "9789722367288")
        XCTAssertEqual(ShareIntake.isbn(in: "ISBN: 978-972-23-6728-8"), "9789722367288")
        XCTAssertNil(ShareIntake.isbn(in: "order 9789722367289 total"), "bad check digit")
        XCTAssertTrue(ShareIntake.isValid("0306406152"))
        XCTAssertFalse(ShareIntake.isValid("0306406153"))
    }

    func testReadsTheLink() throws {
        let url = try XCTUnwrap(URL(string: "goodreads-gui://add?url=https%3A%2F%2Fwww.wook.pt%2Flivro%2Fx&title=Os%20Maias%20%7C%20Wook"))
        let request = try XCTUnwrap(ShareIntake.request(from: url))
        XCTAssertEqual(request.page?.host, "www.wook.pt")
        XCTAssertEqual(ShareIntake.cleanTitle(request.title), "Os Maias")
        XCTAssertNil(ShareIntake.request(from: URL(string: "https://example.com")!))
    }
}

final class KoboSyncTests: XCTestCase {
    func testPlansSendsAndRemovals() {
        let volume = URL(fileURLWithPath: "/Volumes/KOBOeReader")
        let reading = makeEntry(id: "1", title: "Os Maias", author: "Eça de Queirós")
        let queued = makeEntry(id: "2", title: "Dune", author: "Frank Herbert")
        let finished = makeEntry(id: "3", title: "Done", author: "X")
        let files = ["1": URL(fileURLWithPath: "/tmp/1.epub"), "2": URL(fileURLWithPath: "/tmp/2.epub"),
                     "3": URL(fileURLWithPath: "/tmp/3.epub")]
        let shelves = ["currently-reading": [reading], "to-read": [queued], "read": [finished]]
        let plan = KoboSync.plan(volume: volume, files: files, shelves: shelves,
                                 uploads: ["3": "Goodreads/Done - X.epub", "2": "Goodreads/Dune - Frank Herbert.epub"],
                                 onDevice: [])
        XCTAssertEqual(plan.send.map(\.id), ["1"], "already sent books aren't sent again")
        XCTAssertEqual(plan.remove.map(\.id), ["3"], "only finished books the app sent")
        XCTAssertEqual(KoboSync.deviceName(title: "A/B: C?", author: "D", ext: "epub"), "A-B- C- - D.epub")
    }
}

final class PriceWatchTests: XCTestCase {
    func testDrops() {
        let url = URL(string: "https://books.apple.com/x")!
        let old = PriceWatch.Price(amount: 9.99, formatted: "9,99 €", currency: "EUR", url: url)
        XCTAssertTrue(PriceWatch.isDrop(from: old, to: .init(amount: 4.99, formatted: "4,99 €", currency: "EUR", url: url)))
        XCTAssertTrue(PriceWatch.isDrop(from: old, to: .init(amount: 0, formatted: "Grátis", currency: "EUR", url: url)))
        XCTAssertFalse(PriceWatch.isDrop(from: old, to: old))
        XCTAssertFalse(PriceWatch.isDrop(from: nil, to: old), "the first look only remembers")
        XCTAssertFalse(PriceWatch.isDrop(from: old, to: .init(amount: 1, formatted: "$1", currency: "USD", url: url)))
    }
}
