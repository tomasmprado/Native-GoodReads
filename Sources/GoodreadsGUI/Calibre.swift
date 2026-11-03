import AppKit
import SwiftUI

/// Your Calibre library: its books (with their files, ISBNs and any Goodreads
/// ids Calibre's metadata download added), where you stopped in Calibre's
/// reader, and its highlights. Read from `metadata.db`; written back only
/// through Calibre's own `calibredb`, so the library stays Calibre's.
struct CalibreBook: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let authors: [String]
    let isbn: String?
    let goodreadsID: String?
    /// Every identifier Calibre has (isbn, google, goodreads…), kept when writing one.
    var identifiers: [String: String] = [:]
    let files: [URL]
    /// 1–5 stars, when set in Calibre.
    let rating: Int?
    let tags: [String]
    /// From Calibre's reader, when you've read in it.
    let percent: Int?
    let lastRead: Date?

    var author: String { authors.joined(separator: ", ") }

    /// The file to use as your copy: EPUB first, then PDF.
    var readableFile: URL? {
        files.first { $0.pathExtension.lowercased() == "epub" } ?? files.first { $0.pathExtension.lowercased() == "pdf" }
    }

    var asReaderBook: ReaderBook {
        ReaderBook(source: .calibre, sourceID: String(id), title: title, author: author, isbn: isbn,
                   percent: percent, finished: (percent ?? 0) >= 99, finishedOn: nil, lastOpened: lastRead,
                   goodreadsID: goodreadsID)
    }
}

enum Calibre {

    static let app = URL(fileURLWithPath: "/Applications/calibre.app")
    static var calibredb: URL { app.appendingPathComponent("Contents/MacOS/calibredb") }
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: calibredb.path) }

    private static let libraryKey = "calibreLibrary"

    /// The library chosen in Settings, else the one Calibre itself last used.
    static var library: URL? {
        get {
            if let path = UserDefaults.standard.string(forKey: libraryKey) { return URL(fileURLWithPath: path, isDirectory: true) }
            return defaultLibrary
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: libraryKey) }
    }

    static var defaultLibrary: URL? {
        let prefs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/calibre/global.py.json")
        guard let data = try? Data(contentsOf: prefs),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["library_path"] as? String else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("metadata.db").path) ? url : nil
    }

    // MARK: Reading

    static func books(in library: URL) throws -> [CalibreBook] {
        let db = try snapshot(library.appendingPathComponent("metadata.db"))
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        let tables = try Set(Highlights.query(db, "SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0[0] })
        let positions = tables.contains("last_read_positions")
            ? "(SELECT MAX(pos_frac) FROM last_read_positions p WHERE p.book = b.id), (SELECT MAX(epoch) FROM last_read_positions p WHERE p.book = b.id)"
            : "NULL, NULL"
        let rows = try Highlights.query(db, """
            SELECT b.id, b.title, b.path,
              (SELECT group_concat(a.name, '\u{1F}') FROM authors a JOIN books_authors_link l ON l.author = a.id WHERE l.book = b.id),
              (SELECT val FROM identifiers WHERE book = b.id AND type = 'isbn'),
              (SELECT val FROM identifiers WHERE book = b.id AND type = 'goodreads'),
              (SELECT group_concat(type || '\u{1E}' || val, '\u{1F}') FROM identifiers WHERE book = b.id),
              (SELECT group_concat(lower(format) || '\u{1E}' || name, '\u{1F}') FROM data WHERE book = b.id),
              (SELECT r.rating FROM ratings r JOIN books_ratings_link rl ON rl.rating = r.id WHERE rl.book = b.id),
              (SELECT group_concat(t.name, '\u{1F}') FROM tags t JOIN books_tags_link tl ON tl.tag = t.id WHERE tl.book = b.id),
              \(positions)
            FROM books b ORDER BY b.id
            """)
        return rows.compactMap { row -> CalibreBook? in
            guard let id = row[0].flatMap(Int.init), let title = row[1], let path = row[2] else { return nil }
            let folder = library.appendingPathComponent(path, isDirectory: true)
            let identifiers = Dictionary((row[6] ?? "").split(separator: "\u{1F}").compactMap { item -> (String, String)? in
                let parts = item.split(separator: "\u{1E}", maxSplits: 1)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }, uniquingKeysWith: { a, _ in a })
            let files = (row[7] ?? "").split(separator: "\u{1F}").compactMap { item -> URL? in
                let parts = item.split(separator: "\u{1E}", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return folder.appendingPathComponent("\(parts[1]).\(parts[0])")
            }
            return CalibreBook(
                id: id, title: title,
                authors: (row[3] ?? "").split(separator: "\u{1F}").map(String.init),
                isbn: row[4].flatMap { ISBN.normalized($0) ?? ($0.isEmpty ? nil : $0) },
                goodreadsID: row[5].flatMap { $0.isEmpty ? nil : $0 },
                identifiers: identifiers,
                files: files,
                rating: row[8].flatMap(Int.init).flatMap { $0 > 0 ? Int((Double($0) / 2).rounded()) : nil },
                tags: (row[9] ?? "").split(separator: "\u{1F}").map(String.init),
                percent: row[10].flatMap(Double.init).map { Int(($0 * 100).rounded()) },
                lastRead: row[11].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    /// Highlights and notes made in Calibre's reader.
    static func highlights(in library: URL) throws -> [ImportedBook] {
        let db = try snapshot(library.appendingPathComponent("metadata.db"))
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        let tables = try Set(Highlights.query(db, "SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0[0] })
        guard tables.contains("annotations") else { return [] }
        let rows = try Highlights.query(db, """
            SELECT b.title,
              (SELECT group_concat(a.name, ', ') FROM authors a JOIN books_authors_link l ON l.author = a.id WHERE l.book = b.id),
              an.annot_data
            FROM annotations an JOIN books b ON b.id = an.book
            WHERE an.annot_type = 'highlight'
            ORDER BY an.book, an.timestamp
            """)
        var order: [String] = []
        var books: [String: ImportedBook] = [:]
        for row in rows {
            guard let title = row[0], let json = row[2]?.data(using: .utf8),
                  let data = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  (data["removed"] as? Bool) != true else { continue }
            let author = row[1] ?? ""
            let key = "\(title)\u{1F}\(author)"
            if books[key] == nil {
                books[key] = ImportedBook(title: title, author: author, highlights: [], notes: [])
                order.append(key)
            }
            if let text = (data["highlighted_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                books[key]!.highlights.append(text)
            }
            if let note = (data["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                books[key]!.notes.append(note)
            }
        }
        return order.compactMap { books[$0] }
    }

    private static func snapshot(_ db: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: db.path) else {
            throw AppError(verbatim: String(localized: "No Calibre library there — choose the folder that has metadata.db."))
        }
        let temp = fm.temporaryDirectory.appendingPathComponent("calibre-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let target = temp.appendingPathComponent("metadata.db")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: db.path + suffix)
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: URL(fileURLWithPath: target.path + suffix)) }
        }
        return target
    }

    // MARK: Writing back

    /// Calibre's own app is open — calibredb can't change the library then.
    static var isRunning: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "calibre.app/Contents/MacOS/calibre"]
        process.standardOutput = Pipe()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The tag a Goodreads shelf becomes in Calibre.
    static func tag(for shelf: Shelf) -> String { "Goodreads: \(shelf.label)" }

    /// What a book should look like in Calibre to match Goodreads, or nil when it already does.
    struct Update: Equatable, Sendable {
        let bookID: Int
        let title: String
        var rating: Int?
        var tags: [String]?
        var goodreadsID: String?
        /// The book's other identifiers: calibredb replaces them all, so they're written too.
        var otherIdentifiers: [String: String] = [:]

        var fields: [String] {
            var fields: [String] = []
            if let rating { fields.append("rating:\(rating * 2)") }
            if let tags { fields.append("tags:\(tags.joined(separator: ","))") }
            if let goodreadsID {
                var all = otherIdentifiers
                all["goodreads"] = goodreadsID
                fields.append("identifiers:" + all.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))
            }
            return fields
        }
    }

    static func update(for book: CalibreBook, entry: ShelfEntry, shelf: Shelf?) -> Update? {
        var update = Update(bookID: book.id, title: book.title)
        if let stars = entry.rating, stars > 0, stars != book.rating { update.rating = stars }
        if let shelf {
            let wanted = tag(for: shelf)
            let others = book.tags.filter { !$0.hasPrefix("Goodreads: ") }
            if !book.tags.contains(wanted) || book.tags.contains(where: { $0.hasPrefix("Goodreads: ") && $0 != wanted }) {
                update.tags = others + [wanted]
            }
        }
        if book.goodreadsID != entry.bookID, entry.bookID.allSatisfy(\.isNumber) {
            update.goodreadsID = entry.bookID
            update.otherIdentifiers = book.identifiers.filter { $0.key != "goodreads" }
        }
        return update.fields.isEmpty ? nil : update
    }

    /// Runs calibredb set_metadata for each update. Returns how many changed, or throws the first failure.
    static func apply(_ updates: [Update], library: URL) async throws -> Int {
        var done = 0
        for update in updates {
            var arguments = ["set_metadata", "--library-path", library.path, String(update.bookID)]
            for field in update.fields { arguments += ["--field", field] }
            try await run(arguments)
            done += 1
        }
        return done
    }

    private static func run(_ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = calibredb
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { finished in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: AppError(verbatim: output.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

// MARK: - Settings

/// Settings → Reading Apps → Calibre.
struct CalibreSection: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var sync = ReadingAppsSync.shared
    @State private var library = Calibre.library
    @State private var message: String?

    var body: some View {
        Section {
            Toggle("Use my Calibre library", isOn: $prefs.useCalibre)
            LabeledContent("Library") {
                HStack(spacing: 6) {
                    Text(library?.lastPathComponent ?? String(localized: "None found"))
                        .foregroundStyle(library == nil ? .secondary : .primary)
                        .help(library?.path ?? "")
                    Button("Choose…") { choose() }.controlSize(.small)
                }
            }
            .disabled(!prefs.useCalibre)
            Toggle("Use Calibre’s EPUBs and PDFs as my copies", isOn: $prefs.calibreFiles)
                .disabled(!prefs.useCalibre)
            Toggle("Write ratings and shelves back to Calibre", isOn: $prefs.calibreWriteBack)
                .disabled(!prefs.useCalibre || !Calibre.isInstalled)
            HStack {
                Button("Update Calibre Now") {
                    Task {
                        if sync.lastScan == nil { await sync.scan() }
                        message = sync.calibreUpdates.isEmpty
                            ? String(localized: "Calibre already matches Goodreads.")
                            : await sync.writeBackToCalibre()
                    }
                }
                .disabled(!prefs.useCalibre || !Calibre.isInstalled || sync.isWritingCalibre)
                if sync.isWritingCalibre { ProgressView().controlSize(.small) }
                if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Calibre")
        } footer: {
            Text("Books in Calibre are matched to your shelves by Goodreads id, ISBN or title. Their files open in Apple Books and go to your Kobo without being copied; books not on a shelf can be added to Want to Read. Writing back puts your stars, a “Goodreads: Read” style tag and the Goodreads id into Calibre — only while Calibre is closed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = library ?? FileManager.default.homeDirectoryForCurrentUser
        panel.message = String(localized: "Choose your Calibre library — the folder with metadata.db in it.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("metadata.db").path) else {
            message = String(localized: "No Calibre library there — choose the folder that has metadata.db.")
            return
        }
        Calibre.library = url
        library = url
        Task { await sync.scan() }
    }
}
