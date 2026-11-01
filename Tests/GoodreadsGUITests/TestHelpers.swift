import Foundation
@testable import GoodreadsGUI

/// A `ShelfEntry` with sensible defaults, so each test only has to spell out
/// the field it actually cares about.
func makeEntry(
    id: String = "1",
    bookID: String? = nil,
    title: String = "Title",
    author: String = "Author",
    rating: Int? = nil,
    dateRead: String? = nil,
    dateAdded: String? = nil,
    isbn: String? = nil,
    isbn13: String? = nil,
    progress: Int? = nil
) -> ShelfEntry {
    ShelfEntry(
        id: id,
        bookID: bookID ?? id,
        reviewID: nil,
        title: title,
        author: author,
        coverURLString: nil,
        rating: rating,
        dateRead: dateRead,
        dateAdded: dateAdded,
        isbn: isbn,
        isbn13: isbn13,
        progress: progress
    )
}

/// Formats a date the same way the shelf table does ("Aug 12, 2026"), so
/// tests can build fixtures `Suggestions.parseDate` is guaranteed to read
/// back correctly.
func goodreadsDateString(daysAgo: Int, from reference: Date = Date()) -> String {
    let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: reference) ?? reference
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "MMM d, yyyy"
    return formatter.string(from: date)
}
