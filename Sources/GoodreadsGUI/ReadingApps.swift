import AppKit
import Foundation

/// The books in Apple Books on this Mac and on a Kobo e-reader plugged in by
/// USB — how far you are in each and whether you finished it — matched
/// against your Goodreads shelves, so progress, finished books and new books
/// can go to Goodreads without typing them in.
enum ReaderSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleBooks, kobo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleBooks: return String(localized: "Apple Books")
        case .kobo:       return String(localized: "Kobo")
        }
    }
    var symbol: String { self == .appleBooks ? "book" : "rectangle.portrait" }
}

struct ReaderBook: Identifiable, Equatable, Sendable {
    let source: ReaderSource
    /// The app's own id for the book.
    let sourceID: String
    let title: String
    let author: String
    let isbn: String?
    /// 0–100, when the app says.
    let percent: Int?
    let finished: Bool
    let finishedOn: Date?
    let lastOpened: Date?

    var id: String { "\(source.rawValue):\(sourceID)" }
    var started: Bool { (percent ?? 0) > 0 || lastOpened != nil }
}

enum ReadingApps {

    // MARK: Apple Books

    /// Every book in Apple Books' library, samples and audiobooks left out.
    static func appleBooks(folder: URL = Highlights.appleBooksFolder) throws -> [ReaderBook] {
        let library = try snapshot(of: database(in: folder.appendingPathComponent("BKLibrary", isDirectory: true)))
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }

        let columns = try Set(Highlights.query(library, "PRAGMA table_info(ZBKLIBRARYASSET)").compactMap { $0[1] })
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let sql = """
            SELECT ZASSETID, ZTITLE, ZAUTHOR, \(column("ZREADINGPROGRESS")), \(column("ZISFINISHED")),
                   \(column("ZDATEFINISHED")), \(column("ZLASTOPENDATE")), \(column("ZISSAMPLE")), \(column("ZCONTENTTYPE"))
            FROM ZBKLIBRARYASSET WHERE ZTITLE IS NOT NULL
            """
        return try Highlights.query(library, sql).compactMap { row -> ReaderBook? in
            guard let id = row[0], let title = row[1], !title.isEmpty else { return nil }
            if row[7] == "1" { return nil }                          // a sample
            if let type = row[8].flatMap(Int.init), type == 3 { return nil }  // an audiobook
            let progress = row[3].flatMap(Double.init).map { Int(($0 * 100).rounded()) }
            let finished = row[4] == "1" || (progress ?? 0) >= 100
            return ReaderBook(source: .appleBooks, sourceID: id, title: title, author: row[2] ?? "", isbn: nil,
                              percent: progress.map { min(100, max(0, $0)) }, finished: finished,
                              finishedOn: row[5].flatMap(coreDataDate), lastOpened: row[6].flatMap(coreDataDate))
        }
    }

    /// Core Data keeps dates as seconds since 1 January 2001.
    static func coreDataDate(_ text: String) -> Date? {
        Double(text).flatMap { $0 > 0 ? Date(timeIntervalSinceReferenceDate: $0) : nil }
    }

    // MARK: Kobo

    /// The plugged-in Kobo's database, if one is mounted.
    static var koboDatabase: URL? {
        let volumes = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
                                                                    includingPropertiesForKeys: nil)) ?? []
        return volumes
            .map { $0.appendingPathComponent(".kobo/KoboReader.sqlite") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func kobo(database: URL? = koboDatabase) throws -> [ReaderBook] {
        guard let database else { return [] }
        let db = try snapshot(of: database)
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }

        let columns = try Set(Highlights.query(db, "PRAGMA table_info(content)").compactMap { $0[1] })
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        // ContentType 6 is a book (chapters are 9); BookID is set only on chapters.
        let sql = """
            SELECT ContentID, Title, \(column("Attribution")), \(column("ISBN")), \(column("___PercentRead")),
                   \(column("ReadStatus")), \(column("DateLastRead")), \(column("LastTimeFinishedReading"))
            FROM content WHERE ContentType = 6 AND (BookID IS NULL OR BookID = '') AND Title IS NOT NULL
            """
        return try Highlights.query(db, sql).compactMap { row -> ReaderBook? in
            guard let id = row[0], let title = row[1], !title.isEmpty else { return nil }
            let percent = row[4].flatMap(Int.init)
            let status = row[5].flatMap(Int.init) ?? 0        // 0 unread, 1 reading, 2 finished
            let finished = status == 2 || (percent ?? 0) >= 100
            return ReaderBook(source: .kobo, sourceID: id, title: title, author: row[2] ?? "",
                              isbn: row[3].flatMap { $0.isEmpty ? nil : $0 },
                              percent: percent.map { min(100, max(0, $0)) }, finished: finished,
                              finishedOn: row[7].flatMap(isoDate) ?? (finished ? row[6].flatMap(isoDate) : nil),
                              lastOpened: row[6].flatMap(isoDate))
        }
    }

    /// Highlights and notes on the Kobo, for File → Import Highlights.
    static func koboHighlights(database: URL? = koboDatabase) throws -> [ImportedBook] {
        guard let database else {
            throw AppError(verbatim: String(localized: "Connect your Kobo by USB first."))
        }
        let db = try snapshot(of: database)
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        let rows = try Highlights.query(db, """
            SELECT c.Title, c.Attribution, b.Text, b.Annotation
            FROM Bookmark b JOIN content c ON c.ContentID = b.VolumeID
            WHERE (b.Hidden IS NULL OR b.Hidden = 'false' OR b.Hidden = 0)
              AND ((b.Text IS NOT NULL AND b.Text != '') OR (b.Annotation IS NOT NULL AND b.Annotation != ''))
            ORDER BY b.VolumeID, b.DateCreated
            """)
        var order: [String] = []
        var books: [String: ImportedBook] = [:]
        for row in rows {
            guard let title = row[0] else { continue }
            let author = row[1] ?? ""
            let key = "\(title)\u{1F}\(author)"
            if books[key] == nil {
                books[key] = ImportedBook(title: title, author: author, highlights: [], notes: [])
                order.append(key)
            }
            if let text = row[2]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                books[key]!.highlights.append(text)
            }
            if let note = row[3]?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                books[key]!.notes.append(note)
            }
        }
        return order.compactMap { books[$0] }
    }

    static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = TimeZone(identifier: "UTC")
        plain.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return plain.date(from: String(text.prefix(19)))
    }

    // MARK: Files

    private static func database(in folder: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard let db = files.first(where: { $0.pathExtension == "sqlite" }) else {
            throw AppError(verbatim: String(localized: "Apple Books has no library on this Mac yet."))
        }
        return db
    }

    /// A copy (with its journal) to read from, since the app may have it open.
    private static func snapshot(of db: URL) throws -> URL {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let target = temp.appendingPathComponent(db.lastPathComponent)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: db.path + suffix)
            if fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: URL(fileURLWithPath: target.path + suffix))
            }
        }
        return target
    }

    // MARK: Matching

    /// Pairs reader books with your Goodreads books: by ISBN when there is
    /// one, else by title and author.
    static func match(_ books: [ReaderBook], to library: [ShelfEntry]) -> [String: ShelfEntry] {
        var byISBN: [String: ShelfEntry] = [:]
        var byTitle: [String: [ShelfEntry]] = [:]
        for entry in library {
            for isbn in [entry.isbn, entry.isbn13].compactMap({ $0 }) { byISBN[isbn] = entry }
            for key in Highlights.titleKeys(entry.title) { byTitle[key, default: []].append(entry) }
        }
        var result: [String: ShelfEntry] = [:]
        for book in books {
            if let isbn = book.isbn, let hit = byISBN[isbn] { result[book.id] = hit; continue }
            let authors = Highlights.authorTokens(book.author)
            for key in Highlights.titleKeys(book.title) {
                if let hit = byTitle[key]?.first(where: { authors.isEmpty || !Highlights.authorTokens($0.author).isDisjoint(with: authors) }) {
                    result[book.id] = hit
                    break
                }
            }
        }
        return result
    }
}

/// What to do about one reader book.
struct ReaderSuggestion: Identifiable, Equatable {
    enum Kind: Equatable {
        /// On Currently Reading, further along in the app.
        case progress(Int)
        /// Started in the app; on Want to Read on Goodreads.
        case start(Int?)
        /// Finished in the app; not on Read.
        case finished
        /// Not on any of your shelves.
        case add(Shelf)
    }

    let book: ReaderBook
    let entry: ShelfEntry?
    let kind: Kind
    var id: String { book.id }

    /// Whether automatic progress sync does this one (not adding books).
    var isProgress: Bool {
        if case .add = kind { return false }
        return true
    }

    /// Works out what each book needs, given where it is on Goodreads.
    static func plan(books: [ReaderBook], matches: [String: ShelfEntry],
                     shelfOf: (ShelfEntry) -> String?) -> [ReaderSuggestion] {
        books.compactMap { book in
            guard let entry = matches[book.id] else {
                guard book.started || book.finished else { return nil }
                let shelf: Shelf = book.finished ? .read : (book.started ? .currentlyReading : .wantToRead)
                return ReaderSuggestion(book: book, entry: nil, kind: .add(shelf))
            }
            let shelf = shelfOf(entry)
            if book.finished {
                return shelf == Shelf.read.name ? nil : ReaderSuggestion(book: book, entry: entry, kind: .finished)
            }
            if shelf == Shelf.currentlyReading.name, let percent = book.percent, percent > (entry.progress ?? 0) + 1 {
                return ReaderSuggestion(book: book, entry: entry, kind: .progress(percent))
            }
            if shelf == Shelf.wantToRead.name, (book.percent ?? 0) > 0 {
                return ReaderSuggestion(book: book, entry: entry, kind: .start(book.percent))
            }
            return nil
        }
    }
}
