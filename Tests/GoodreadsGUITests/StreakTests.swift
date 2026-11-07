import XCTest
@testable import GoodreadsGUI

final class StreakTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2   // Monday
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar
    }()
    private func day(_ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: hour))!
    }

    func testRunsAndLongest() {
        // 2, 3, 4 November, then 8, 9, 10 (Sunday 8 ends one week).
        let days: Set<Date> = [day(2), day(3), day(4), day(6), day(8), day(9), day(10)]
        let streak = ReadingStreak.compute(days: days, weekGoal: 5, now: day(10, hour: 20), calendar: calendar)!
        XCTAssertEqual(streak.length, 3)
        XCTAssertEqual(streak.longest, 3)
        XCTAssertEqual(streak.weekDays, 2, "Monday 9 and Tuesday 10")
        XCTAssertTrue(streak.readToday(on: day(10, hour: 22), calendar: calendar))
    }

    func testStreakLivesUntilTheEndOfTheNextDay() {
        let streak = ReadingStreak.compute(days: [day(9), day(10)], weekGoal: 5, now: day(10), calendar: calendar)!
        XCTAssertEqual(streak.current(on: day(11, hour: 23), calendar: calendar), 2, "there's still today")
        XCTAssertTrue(streak.atRisk(on: day(11), calendar: calendar))
        XCTAssertEqual(streak.current(on: day(12, hour: 1), calendar: calendar), 0, "a whole day missed")
        XCTAssertEqual(streak.daysThisWeek(on: day(16), calendar: calendar), 0, "a new week")
    }

    func testNothingRead() {
        XCTAssertNil(ReadingStreak.compute(days: [], weekGoal: 5, now: day(10), calendar: calendar))
    }
}

final class BookcaseKeysTests: XCTestCase {
    func testArrowKeys() {
        let rows = [0..<4, 4..<6, 6..<10]
        XCTAssertEqual(Bookshelf.move(from: nil, .right, rows: rows), 0)
        XCTAssertEqual(Bookshelf.move(from: 3, .right, rows: rows), 4)
        XCTAssertEqual(Bookshelf.move(from: 0, .left, rows: rows), 0)
        XCTAssertEqual(Bookshelf.move(from: 3, .down, rows: rows), 5, "nearest place in a shorter row")
        XCTAssertEqual(Bookshelf.move(from: 5, .down, rows: rows), 7)
        XCTAssertEqual(Bookshelf.move(from: 1, .up, rows: rows), 1, "nothing above")
    }

    func testCoverColour() {
        // A red cover with a white border: red wins over the white.
        let pixels = Array(repeating: RGB(r: 0.8, g: 0.1, b: 0.1), count: 300)
            + Array(repeating: RGB(r: 1, g: 1, b: 1), count: 200)
        let main = SpineColours.mainColour(pixels)!
        XCTAssertGreaterThan(main.r, 0.7)
        XCTAssertLessThan(main.g, 0.2)
        let cloth = SpineColours.cloth(RGB(r: 1, g: 1, b: 1))
        XCTAssertLessThanOrEqual(cloth.r, 0.9, "never quite white")
    }

    func testNextVolume() {
        func entry(_ id: String, _ title: String, read: String? = nil) -> ShelfEntry {
            var e = ShelfEntry(id: id, bookID: id, reviewID: nil, title: title, author: "Eça de Queirós", coverURLString: nil)
            e.dateRead = read
            return e
        }
        let next = Volumes.nextToRead(read: [entry("a", "Os Maias I", read: "Nov 1, 2026")],
                                      waiting: [entry("c", "Os Maias III"), entry("b", "Os Maias II"), entry("x", "O Primo Basílio")])
        XCTAssertEqual(next.map(\.entry.id), ["b"])
        XCTAssertEqual(next.first.map { "\($0.read)/\($0.total)" }, "1/3")
    }
}
