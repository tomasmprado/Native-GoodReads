import XCTest
@testable import GoodreadsGUI

/// Makes a small SQLite database with `sql`, the way the reading apps lay theirs out.
private func makeDatabase(at url: URL, _ sql: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [url.path, sql]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
}

final class ProfileDetailsTests: XCTestCase {

    func testChallengeWordings() {
        XCTAssertEqual(ProfileDetails.parseChallenge("Maria Mira has read 61 books of their goal of 52! 117%", year: 2026),
                       .init(year: 2026, read: 61, goal: 52))
        XCTAssertEqual(ProfileDetails.parseChallenge("12 of 40 books read", year: nil)?.goal, 40)
        XCTAssertNil(ProfileDetails.parseChallenge("Join the challenge", year: nil))
        XCTAssertEqual(GoodreadsChallenge.parse(text: "Maria Mira has read 61 books of their goal of 52!")?.goal, 52)
    }

    func testDecodesWhatThePageScriptReturns() throws {
        // Shaped like the script's output on a real profile (2026-11-03).
        let raw = #"""
        {"ok":true,"rows":[{"title":"Details","value":"Porto Salvo, 14"},{"title":"Activity","value":"Joined in November 2022, last active in October 2026"}],
         "challenge":"Maria Mira has read 61 books of their goal of 52! 117%","challengeYear":2026,
         "favourites":[{"url":"https://www.goodreads.com/book/show/4671.The_Great_Gatsby","title":"The Great Gatsby by F. Scott Fitzgerald","cover":"https://i.gr-assets.com/books/1490528560l/4671._SY75_.jpg"}],
         "reading":[{"url":"https://www.goodreads.com/book/show/54493401-project-hail-mary","title":"Project Hail Mary","author":"Andy Weir","cover":null}],
         "shelves":["to-read‎ (50)","read‎ (196)","did-not-finish"],
         "quotes":[{"text":"“Not all those who wander are lost.”","by":"J.R.R. Tolkien"}],
         "genres":["Classics","Fantasy"],
         "friends":[{"name":"Tomás Prado","url":"https://www.goodreads.com/user/show/197669307-tom-s-prado","avatar":"https://images.gr-assets.com/users/1p2/197669307.jpg"}],
         "friendCount":2,"following":[{"name":"Andy Weir","url":"/author/show/6540057.Andy_Weir","avatar":null}],
         "yearInBooks":"https://www.goodreads.com/user/year_in_books/2025/158604205","restricted":false}
        """#
        let details = try XCTUnwrap(ProfileDetails.decode(raw))
        XCTAssertEqual(details.rows.count, 2)
        XCTAssertEqual(details.challenge, .init(year: 2026, read: 61, goal: 52))
        XCTAssertEqual(details.favouriteBooks.first?.title, "The Great Gatsby")
        XCTAssertEqual(details.favouriteBooks.first?.author, "F. Scott Fitzgerald")
        XCTAssertEqual(details.favouriteBooks.first?.bookID, "4671")
        XCTAssertEqual(details.favouriteBooks.first?.coverURL?.absoluteString,
                       "https://i.gr-assets.com/books/1490528560l/4671.jpg", "full-size cover")
        XCTAssertEqual(details.currentlyReading.first?.author, "Andy Weir")
        XCTAssertEqual(details.shelves, [.init(name: "to-read", count: 50), .init(name: "read", count: 196),
                                         .init(name: "did-not-finish", count: nil)])
        XCTAssertEqual(details.quotes.first?.attribution, "J.R.R. Tolkien")
        XCTAssertEqual(details.friendCount, 2)
        XCTAssertTrue(details.following.first?.isAuthor ?? false)
        XCTAssertEqual(details.following.first?.url.absoluteString, "https://www.goodreads.com/author/show/6540057.Andy_Weir")
        XCTAssertFalse(details.isEmpty)
        XCTAssertNil(ProfileDetails.decode(#"{"ok":false}"#))
    }
}

final class ReadingAppsTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("reading-apps-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testReadsAppleBooksLibrary() throws {
        let db = folder.appendingPathComponent("BKLibrary/BKLibrary-1.sqlite")
        try makeDatabase(at: db, """
            CREATE TABLE ZBKLIBRARYASSET (Z_PK INTEGER PRIMARY KEY, ZASSETID TEXT, ZTITLE TEXT, ZAUTHOR TEXT,
              ZREADINGPROGRESS REAL, ZISFINISHED INTEGER, ZDATEFINISHED REAL, ZLASTOPENDATE REAL, ZISSAMPLE INTEGER, ZCONTENTTYPE INTEGER);
            INSERT INTO ZBKLIBRARYASSET VALUES (1,'A1','Dune','Frank Herbert',0.42,0,NULL,780000000,0,1);
            INSERT INTO ZBKLIBRARYASSET VALUES (2,'A2','Middlemarch','George Eliot',1.0,1,790000000,790000000,0,1);
            INSERT INTO ZBKLIBRARYASSET VALUES (3,'A3','Sample Book','Someone',0.1,0,NULL,NULL,1,1);
            INSERT INTO ZBKLIBRARYASSET VALUES (4,'A4','An Audiobook','Someone',0.5,0,NULL,NULL,0,3);
            """)
        let books = try ReadingApps.appleBooks(folder: folder)
        XCTAssertEqual(books.map(\.title), ["Dune", "Middlemarch"], "samples and audiobooks left out")
        XCTAssertEqual(books[0].percent, 42)
        XCTAssertFalse(books[0].finished)
        XCTAssertTrue(books[1].finished)
        XCTAssertEqual(books[1].finishedOn, Date(timeIntervalSinceReferenceDate: 790_000_000))
    }

    func testReadsKobo() throws {
        let db = folder.appendingPathComponent(".kobo/KoboReader.sqlite")
        try makeDatabase(at: db, """
            CREATE TABLE content (ContentID TEXT, ContentType INTEGER, BookID TEXT, Title TEXT, Attribution TEXT, ISBN TEXT,
              ___PercentRead INTEGER, ReadStatus INTEGER, DateLastRead TEXT, LastTimeFinishedReading TEXT);
            INSERT INTO content VALUES ('book1',6,NULL,'Ensaio sobre a Cegueira','José Saramago','9789720046710',37,1,'2026-10-30T21:10:00Z',NULL);
            INSERT INTO content VALUES ('book1!ch1',9,'book1','Capítulo 1',NULL,NULL,0,0,NULL,NULL);
            INSERT INTO content VALUES ('book2',6,NULL,'Os Maias','Eça de Queirós',NULL,100,2,'2026-09-01T10:00:00Z','2026-09-01T10:00:00Z');
            CREATE TABLE Bookmark (BookmarkID TEXT, VolumeID TEXT, Text TEXT, Annotation TEXT, Hidden TEXT, DateCreated TEXT);
            INSERT INTO Bookmark VALUES ('b1','book1','Se podes olhar, vê.','Lindo','false','2026-10-30T21:00:00Z');
            INSERT INTO Bookmark VALUES ('b2','book1','Escondido',NULL,'true','2026-10-30T21:01:00Z');
            """)
        let books = try ReadingApps.kobo(database: db)
        XCTAssertEqual(books.map(\.title), ["Ensaio sobre a Cegueira", "Os Maias"], "chapters left out")
        XCTAssertEqual(books[0].percent, 37)
        XCTAssertEqual(books[0].isbn, "9789720046710")
        XCTAssertTrue(books[1].finished)
        XCTAssertNotNil(books[1].finishedOn)

        let highlights = try ReadingApps.koboHighlights(database: db)
        XCTAssertEqual(highlights.first?.highlights, ["Se podes olhar, vê."], "hidden ones left out")
        XCTAssertEqual(highlights.first?.notes, ["Lindo"])
    }

    func testMatchesAndPlans() {
        func book(_ id: String, _ title: String, isbn: String? = nil, percent: Int? = nil, finished: Bool = false) -> ReaderBook {
            ReaderBook(source: .kobo, sourceID: id, title: title, author: "Author Name", isbn: isbn, percent: percent,
                       finished: finished, finishedOn: nil, lastOpened: percent == nil ? nil : Date())
        }
        let reading = makeEntry(id: "1", title: "Reading Now", author: "Author Name", progress: 20)
        let queued = makeEntry(id: "2", title: "Queued", author: "Author Name")
        let byISBN = makeEntry(id: "3", title: "Different Title", author: "Someone", isbn13: "9780000000003")
        let books = [book("a", "Reading Now", percent: 55), book("b", "Queued", percent: 10),
                     book("c", "Whatever", isbn: "9780000000003", finished: true),
                     book("d", "Not Mine", percent: 30), book("e", "Untouched")]
        let matches = ReadingApps.match(books, to: [reading, queued, byISBN])
        XCTAssertEqual(matches["kobo:a"]?.bookID, "1")
        XCTAssertEqual(matches["kobo:c"]?.bookID, "3", "matched by ISBN")
        XCTAssertNil(matches["kobo:d"])

        let shelves = ["1": "currently-reading", "2": "to-read", "3": "to-read"]
        let plan = ReaderSuggestion.plan(books: books, matches: matches) { shelves[$0.bookID] }
        let kinds = Dictionary(uniqueKeysWithValues: plan.map { ($0.book.sourceID, $0.kind) })
        XCTAssertEqual(kinds["a"], .progress(55))
        XCTAssertEqual(kinds["b"], .start(10))
        XCTAssertEqual(kinds["c"], .finished)
        XCTAssertEqual(kinds["d"], .add(.currentlyReading))
        XCTAssertNil(kinds["e"], "never opened, not on a shelf: nothing to do")
        XCTAssertFalse(plan.first { $0.book.sourceID == "d" }!.isProgress)

        // Progress only goes forward.
        let behind = ReaderSuggestion.plan(books: [book("a", "Reading Now", percent: 10)], matches: matches) { shelves[$0.bookID] }
        XCTAssertTrue(behind.isEmpty)
    }

    func testDates() {
        XCTAssertEqual(ReadingApps.coreDataDate("0"), nil)
        XCTAssertEqual(ReadingApps.coreDataDate("100"), Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertNotNil(ReadingApps.isoDate("2026-10-30T21:10:00Z"))
        XCTAssertNotNil(ReadingApps.isoDate("2026-10-30T21:10:00.123Z"))
        XCTAssertNotNil(ReadingApps.isoDate("2026-10-30T21:10:00"))
    }
}

final class AuthorLinksTests: XCTestCase {

    func testWikipediaNameAndDescription() {
        XCTAssertTrue(AuthorWikipedia.sameName("J. R. R. Tolkien", "J.R.R. Tolkien"))
        XCTAssertTrue(AuthorWikipedia.sameName("Paul Auster (escritor)", "Paul Auster"))
        XCTAssertFalse(AuthorWikipedia.sameName("Elfos (Tolkien)", "J.R.R. Tolkien"))
        XCTAssertTrue(AuthorWikipedia.isWriter("escritor, poeta, filólogo e professor universitário britânico"))
        XCTAssertTrue(AuthorWikipedia.isWriter("American novelist"))
        XCTAssertFalse(AuthorWikipedia.isWriter("American footballer"))
        XCTAssertFalse(AuthorWikipedia.isWriter(nil))
    }

    func testStores() {
        let pt = StoreLinks.links(title: "Os Maias", author: "Eça de Queirós", region: "PT")
        XCTAssertTrue(pt.contains { $0.name == "Kobo" && $0.url.absoluteString.hasPrefix("https://www.kobo.com/pt/pt/search?query=") })
        XCTAssertTrue(pt.contains { $0.name == "Kindle" && $0.url.absoluteString.contains("i=digital-text") })
        XCTAssertEqual(StoreLinks.koboStore("JP"), "us/en")
    }
}
