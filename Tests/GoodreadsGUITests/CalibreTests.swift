import XCTest
@testable import GoodreadsGUI

final class CalibreTests: XCTestCase {

    private func makeLibrary() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("calibre-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Eca/Os Maias (1)"), withIntermediateDirectories: true)
        let sql = """
        CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, path TEXT);
        CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE books_authors_link (book INTEGER, author INTEGER);
        CREATE TABLE identifiers (book INTEGER, type TEXT, val TEXT);
        CREATE TABLE data (book INTEGER, format TEXT, name TEXT);
        CREATE TABLE ratings (id INTEGER PRIMARY KEY, rating INTEGER);
        CREATE TABLE books_ratings_link (book INTEGER, rating INTEGER);
        CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE books_tags_link (book INTEGER, tag INTEGER);
        CREATE TABLE last_read_positions (book INTEGER, pos_frac REAL, epoch REAL);
        CREATE TABLE annotations (book INTEGER, annot_type TEXT, annot_data TEXT, timestamp REAL);
        INSERT INTO books VALUES (1, 'Os Maias', 'Eca/Os Maias (1)');
        INSERT INTO authors VALUES (1, 'Eça de Queirós');
        INSERT INTO books_authors_link VALUES (1, 1);
        INSERT INTO identifiers VALUES (1, 'goodreads', '123'), (1, 'isbn', '978-972-23-6728-8');
        INSERT INTO data VALUES (1, 'PDF', 'Os Maias - Eca'), (1, 'EPUB', 'Os Maias - Eca');
        INSERT INTO ratings VALUES (1, 8);
        INSERT INTO books_ratings_link VALUES (1, 1);
        INSERT INTO tags VALUES (1, 'Clássicos'), (2, 'Goodreads: Want to Read');
        INSERT INTO books_tags_link VALUES (1, 1), (1, 2);
        INSERT INTO last_read_positions VALUES (1, 0.42, 1700000000);
        INSERT INTO annotations VALUES (1, 'highlight', '{"highlighted_text":"Uma frase.","notes":"Gosto"}', 1);
        INSERT INTO annotations VALUES (1, 'highlight', '{"highlighted_text":"Apagada","removed":true}', 2);
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [folder.appendingPathComponent("metadata.db").path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return folder
    }

    func testReadsLibrary() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library) }
        let books = try Calibre.books(in: library)
        XCTAssertEqual(books.count, 1)
        let book = try XCTUnwrap(books.first)
        XCTAssertEqual(book.title, "Os Maias")
        XCTAssertEqual(book.author, "Eça de Queirós")
        XCTAssertEqual(book.goodreadsID, "123")
        XCTAssertEqual(book.isbn, "9789722367288")
        XCTAssertEqual(book.rating, 4, "Calibre stores 0–10")
        XCTAssertEqual(book.percent, 42)
        XCTAssertEqual(book.readableFile?.lastPathComponent, "Os Maias - Eca.epub", "EPUB before PDF")
        XCTAssertEqual(book.tags.sorted(), ["Clássicos", "Goodreads: Want to Read"])
        XCTAssertEqual(book.identifiers, ["goodreads": "123", "isbn": "978-972-23-6728-8"])

        let highlights = try Calibre.highlights(in: library)
        XCTAssertEqual(highlights.first?.highlights, ["Uma frase."])
        XCTAssertEqual(highlights.first?.notes, ["Gosto"])
    }

    func testMatchesByGoodreadsIDFirst() {
        let book = ReaderBook(source: .calibre, sourceID: "1", title: "Something else entirely", author: "",
                              isbn: nil, percent: nil, finished: false, finishedOn: nil, lastOpened: nil, goodreadsID: "123")
        let entry = ShelfEntry(id: "r1", bookID: "123", reviewID: nil, title: "Os Maias", author: "Eça", coverURLString: nil)
        XCTAssertEqual(ReadingApps.match([book], to: [entry])[book.id]?.bookID, "123")
    }

    func testUpdateBringsCalibreInLine() {
        let book = CalibreBook(id: 1, title: "Os Maias", authors: ["Eça"], isbn: nil, goodreadsID: nil,
                               identifiers: ["isbn": "9789722367288", "google": "abc"], files: [],
                               rating: 3, tags: ["Clássicos", "Goodreads: Want to Read"], percent: nil, lastRead: nil)
        var entry = ShelfEntry(id: "r1", bookID: "123", reviewID: nil, title: "Os Maias", author: "Eça", coverURLString: nil)
        entry.rating = 5
        let update = Calibre.update(for: book, entry: entry, shelf: .read)
        XCTAssertEqual(update?.fields, ["rating:10", "tags:Clássicos,Goodreads: Read", "identifiers:goodreads:123,google:abc,isbn:9789722367288"])

        let inLine = CalibreBook(id: 1, title: "Os Maias", authors: ["Eça"], isbn: nil, goodreadsID: "123", files: [],
                                 rating: 5, tags: ["Goodreads: Read"], percent: nil, lastRead: nil)
        XCTAssertNil(Calibre.update(for: inLine, entry: entry, shelf: .read))
    }
}
