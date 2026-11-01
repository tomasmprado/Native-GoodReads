import XCTest
@testable import GoodreadsGUI

final class CSVExportTests: XCTestCase {

    /// One literal double-quote character, spelled out so the expected
    /// values below can be built by straightforward concatenation instead
    /// of counting quote characters inside a string literal by eye.
    private let q = "\""

    func testHeaderMatchesExpectedColumns() {
        XCTAssertEqual(
            CSVExport.header,
            "Book Id,Title,Author,ISBN,ISBN13,My Rating,Date Read,Date Added,Shelf"
        )
    }

    /// The CSV-escaping and the Excel-safe ISBN formatting together, in one
    /// worst-case row: a quote inside the title, a comma inside the author,
    /// and both ISBN columns populated.
    ///
    /// RFC 4180 escaping wraps every field in quotes and doubles any quote
    /// inside it. Goodreads' own export additionally wraps an ISBN as
    /// `="0439023483"` so a spreadsheet treats the cell as text — after RFC
    /// 4180 escaping wraps *that* in quotes too, the two quotes it already
    /// contains each double, so the field becomes `"=""0439023483"""`.
    func testDataLineEscapesQuotesCommasAndWrapsISBNs() {
        let title = "He said " + q + "hi" + q          // He said "hi"
        let entry = makeEntry(
            id: "r1", bookID: "123", title: title, author: "Doe, Jane",
            rating: 5, dateRead: "Aug 12, 2026", dateAdded: "Jan 1, 2020",
            isbn: "0439023483", isbn13: "9780439023528"
        )

        let line = CSVExport.dataLines(for: [entry], shelf: .read).first

        let expectedTitleField = q + "He said " + q + q + "hi" + q + q + q
        let expectedISBNField = q + "=" + q + q + "0439023483" + q + q + q
        let expectedISBN13Field = q + "=" + q + q + "9780439023528" + q + q + q

        let expected = [
            q + "123" + q,
            expectedTitleField,
            q + "Doe, Jane" + q,
            expectedISBNField,
            expectedISBN13Field,
            q + "5" + q,
            q + "Aug 12, 2026" + q,
            q + "Jan 1, 2020" + q,
            q + "read" + q
        ].joined(separator: ",")

        XCTAssertEqual(line, expected)
    }

    func testDataLineLeavesAbsentFieldsAsEmptyQuotedStrings() {
        let entry = makeEntry(id: "r1", bookID: "123", title: "Plain Title", author: "Plain Author")

        let line = CSVExport.dataLines(for: [entry], shelf: .wantToRead).first
        let empty = q + q

        let expected = [
            q + "123" + q, q + "Plain Title" + q, q + "Plain Author" + q,
            empty, empty, empty, empty, empty,
            q + "to-read" + q
        ].joined(separator: ",")

        XCTAssertEqual(line, expected)
    }

    func testCombinedExportHasOneHeaderAndNoBlankRowsForEmptyShelves() {
        let entries = [makeEntry(id: "r1", bookID: "123")]
        let lines = [CSVExport.header] + CSVExport.dataLines(for: entries, shelf: .read)
                                       + CSVExport.dataLines(for: [], shelf: .currentlyReading)
        XCTAssertEqual(lines.count, 2)   // header + the one real row, nothing for the empty shelf
    }
}
