import XCTest
@testable import GoodreadsGUI

final class ReadingStatsTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testCountsPerYearFillGapsUpToThisYear() {
        let entries = [
            makeEntry(id: "1", dateRead: "Mar 3, 2023"),
            makeEntry(id: "2", dateRead: "Jan 9, 2025"),
            makeEntry(id: "3", dateRead: "Feb 1, 2025"),
        ]
        let stats = ReadingStats.compute(from: entries, now: date(2026, 6, 1), calendar: calendar)
        XCTAssertEqual(stats.byYear.map(\.year), [2023, 2024, 2025, 2026])
        XCTAssertEqual(stats.byYear.map(\.count), [1, 0, 2, 0])
        XCTAssertEqual(stats.totalRead, 3)
        XCTAssertEqual(stats.readThisYear, 0)
    }

    func testThisYearByMonth() {
        let entries = [
            makeEntry(id: "1", dateRead: "Jan 9, 2026"),
            makeEntry(id: "2", dateRead: "Jan 20, 2026"),
            makeEntry(id: "3", dateRead: "Dec 1, 2026"),
            makeEntry(id: "4", dateRead: "Dec 1, 2025"),
        ]
        let stats = ReadingStats.compute(from: entries, now: date(2026, 12, 15), calendar: calendar)
        XCTAssertEqual(stats.readThisYear, 3)
        XCTAssertEqual(stats.thisYearByMonth[0], 2)
        XCTAssertEqual(stats.thisYearByMonth[11], 1)
    }

    func testAverageIgnoresUnrated() {
        let entries = [
            makeEntry(id: "1", rating: 5),
            makeEntry(id: "2", rating: 3),
            makeEntry(id: "3", rating: nil),
            makeEntry(id: "4", rating: 0),
        ]
        let stats = ReadingStats.compute(from: entries, calendar: calendar)
        XCTAssertEqual(stats.averageRating ?? 0, 4.0, accuracy: 0.001)
        XCTAssertEqual(stats.ratingCounts, [0, 0, 1, 0, 1])
    }

    func testNoRatingsMeansNoAverage() {
        let stats = ReadingStats.compute(from: [makeEntry()], calendar: calendar)
        XCTAssertNil(stats.averageRating)
    }

    func testTopAuthorsOnlyRepeatsSortedByCount() {
        let entries = [
            makeEntry(id: "1", author: "B"), makeEntry(id: "2", author: "B"),
            makeEntry(id: "3", author: "A"), makeEntry(id: "4", author: "A"), makeEntry(id: "5", author: "A"),
            makeEntry(id: "6", author: "C"),
        ]
        let stats = ReadingStats.compute(from: entries, calendar: calendar)
        XCTAssertEqual(stats.topAuthors.map(\.author), ["A", "B"])
        XCTAssertEqual(stats.topAuthors.map(\.count), [3, 2])
    }

    func testExpectedByToday() {
        // Halfway through a 365-day year: about half the goal.
        let mid = date(2026, 7, 2)   // day 183
        XCTAssertEqual(ReadingStats.expectedByToday(goal: 24, now: mid, calendar: calendar), 12)
        XCTAssertEqual(ReadingStats.expectedByToday(goal: 0, now: mid, calendar: calendar), 0)
        XCTAssertEqual(ReadingStats.expectedByToday(goal: 24, now: date(2026, 12, 31), calendar: calendar), 24)
    }
}

final class FriendNotifierTests: XCTestCase {

    private func friend(_ id: String, _ label: String?, _ book: String?) -> GoodreadsFriends.Friend {
        GoodreadsFriends.Friend(id: id, name: "Friend \(id)", avatarURL: nil, profileURL: nil,
                                statusLabel: label, statusBookTitle: book)
    }

    func testNewFriendsAreRecordedSilently() {
        let result = FriendNotifier.changes(from: [:], to: [friend("1", "Currently reading", "Dune")])
        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertEqual(result.snapshot["1"], "Currently reading|Dune")
    }

    func testChangedBookIsReported() {
        let old = ["1": "Currently reading|Dune"]
        let result = FriendNotifier.changes(from: old, to: [friend("1", "Currently reading", "Emma")])
        XCTAssertEqual(result.changes.count, 1)
        XCTAssertEqual(result.changes.first?.title, "Friend 1")
        XCTAssertEqual(result.changes.first?.body, "Currently reading: Emma")
    }

    func testUnchangedIsQuiet() {
        let old = ["1": "Currently reading|Dune"]
        let result = FriendNotifier.changes(from: old, to: [friend("1", "Currently reading", "Dune")])
        XCTAssertTrue(result.changes.isEmpty)
    }

    func testClearedStatusIsQuiet() {
        let old = ["1": "Currently reading|Dune"]
        let result = FriendNotifier.changes(from: old, to: [friend("1", nil, nil)])
        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertEqual(result.snapshot["1"], "")
    }
}
