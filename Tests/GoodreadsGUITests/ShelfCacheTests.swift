import XCTest
@testable import GoodreadsGUI

/// Only the pure time math (`age`, `isStale`) — deliberately not exercising
/// `read`/`write`, which touch the real Application Support directory and
/// have no business doing that as a side effect of running the test suite.
final class ShelfCacheTests: XCTestCase {

    func testAgeBuckets() {
        XCTAssertEqual(ShelfCache.age(Date()), "just now")
        XCTAssertEqual(ShelfCache.age(Date().addingTimeInterval(-120)), "2m ago")
        XCTAssertEqual(ShelfCache.age(Date().addingTimeInterval(-3 * 3600)), "3h ago")
        XCTAssertEqual(ShelfCache.age(Date().addingTimeInterval(-2 * 86400)), "2d ago")
    }

    func testIsStaleUsesTheDefaultTTL() {
        XCTAssertFalse(ShelfCache.isStale(Date()))
        XCTAssertFalse(ShelfCache.isStale(Date().addingTimeInterval(-3 * 3600)))
        XCTAssertTrue(ShelfCache.isStale(Date().addingTimeInterval(-7 * 3600)))
    }

    func testIsStaleRespectsACustomTTL() {
        let twoHoursAgo = Date().addingTimeInterval(-2 * 3600)
        XCTAssertFalse(ShelfCache.isStale(twoHoursAgo, ttl: 3 * 3600))
        XCTAssertTrue(ShelfCache.isStale(twoHoursAgo, ttl: 3600))
    }
}
