import AppKit
import SQLite3
import SwiftUI
import UniformTypeIdentifiers

/// Highlights and notes from one book in Apple Books or on a Kindle.
struct ImportedBook: Identifiable, Equatable, Sendable {
    let title: String
    let author: String
    var highlights: [String]
    var notes: [String]

    var id: String { "\(title)\u{1F}\(author)" }
}

enum HighlightSource: String, CaseIterable, Identifiable {
    case appleBooks, kindle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleBooks: return String(localized: "Apple Books")
        case .kindle:     return String(localized: "Kindle (My Clippings.txt)")
        }
    }
}

enum Highlights {

    // MARK: Kindle

    /// Parses a Kindle's `documents/My Clippings.txt`. Bookmarks are skipped,
    /// and a highlight you later extended only counts once (the longer one).
    static func parseKindle(_ text: String) -> [ImportedBook] {
        var order: [String] = []
        var books: [String: ImportedBook] = [:]

        let clean = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
        for block in clean.components(separatedBy: "==========") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .drop { $0.isEmpty }
            guard let header = lines.first, lines.count >= 2 else { continue }
            let meta = lines.dropFirst().first ?? ""
            let body = lines.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard meta.hasPrefix("-"), !body.isEmpty else { continue }
            let kind = meta.lowercased()
            if kind.contains("bookmark") || kind.contains("marcador") { continue }
            let isNote = kind.contains("note") || kind.contains("nota")

            let (title, author) = splitKindleHeader(header)
            let key = "\(title)\u{1F}\(author)"
            if books[key] == nil {
                books[key] = ImportedBook(title: title, author: author, highlights: [], notes: [])
                order.append(key)
            }
            if isNote {
                books[key]!.notes.append(body)
            } else {
                books[key]!.highlights.append(body)
            }
        }
        return order.compactMap { key in
            books[key].map { book in
                var book = book
                book.highlights = dedupe(book.highlights)
                book.notes = dedupe(book.notes)
                return book
            }
        }
    }

    /// "Dune (Herbert, Frank)" → ("Dune", "Frank Herbert"). The author is the
    /// last parenthesised part, since titles can have their own.
    static func splitKindleHeader(_ header: String) -> (String, String) {
        guard header.hasSuffix(")"), let open = header.lastIndex(of: "(") else { return (header, "") }
        let title = header[..<open].trimmingCharacters(in: .whitespaces)
        var author = String(header[header.index(after: open)..<header.index(before: header.endIndex)])
        let parts = author.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 { author = "\(parts[1]) \(parts[0])" }
        return (title.isEmpty ? header : title, author)
    }

    /// Drops repeats, and any highlight that's part of a longer one.
    static func dedupe(_ items: [String]) -> [String] {
        var kept: [String] = []
        for item in items.sorted(by: { $0.count > $1.count }) where !kept.contains(where: { $0.contains(item) }) {
            kept.append(item)
        }
        // Back in reading order.
        return items.filter { kept.contains($0) }.reduce(into: []) { result, item in
            if !result.contains(item) { result.append(item) }
        }
    }

    // MARK: Apple Books

    static let appleBooksFolder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.apple.iBooksX/Data/Documents", isDirectory: true)

    /// Reads Apple Books' own databases, from `folder` (its Documents folder).
    /// They're copied first, since Books may have them open.
    static func readAppleBooks(folder: URL = appleBooksFolder) throws -> [ImportedBook] {
        let fm = FileManager.default
        func database(in sub: String) throws -> URL {
            let dir = folder.appendingPathComponent(sub, isDirectory: true)
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            guard let db = files.first(where: { $0.pathExtension == "sqlite" }) else {
                throw AppError(verbatim: String(localized: "Apple Books has no highlights on this Mac yet."))
            }
            return db
        }
        let annotations = try database(in: "AEAnnotation")
        let library = try database(in: "BKLibrary")

        let temp = fm.temporaryDirectory.appendingPathComponent("highlights-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        func copy(_ db: URL) throws -> URL {
            let target = temp.appendingPathComponent(db.lastPathComponent)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: db.path + suffix)
                if fm.fileExists(atPath: source.path) {
                    try fm.copyItem(at: source, to: URL(fileURLWithPath: target.path + suffix))
                }
            }
            return target
        }

        let titles = try query(copy(library), "SELECT ZASSETID, ZTITLE, ZAUTHOR FROM ZBKLIBRARYASSET")
        var assets: [String: (String, String)] = [:]
        for row in titles {
            if let id = row[0], let title = row[1] { assets[id] = (title, row[2] ?? "") }
        }

        let rows = try query(copy(annotations), """
            SELECT ZANNOTATIONASSETID, ZANNOTATIONSELECTEDTEXT, ZANNOTATIONNOTE
            FROM ZAEANNOTATION
            WHERE ZANNOTATIONDELETED = 0 AND (ZANNOTATIONSELECTEDTEXT IS NOT NULL OR ZANNOTATIONNOTE IS NOT NULL)
            ORDER BY ZANNOTATIONASSETID, ZANNOTATIONCREATIONDATE
            """)

        var order: [String] = []
        var books: [String: ImportedBook] = [:]
        for row in rows {
            guard let asset = row[0], let (title, author) = assets[asset] else { continue }
            if books[asset] == nil {
                books[asset] = ImportedBook(title: title, author: author, highlights: [], notes: [])
                order.append(asset)
            }
            if let text = row[1]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                books[asset]!.highlights.append(text)
            }
            if let note = row[2]?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                books[asset]!.notes.append(note)
            }
        }
        return order.compactMap { books[$0] }.filter { !$0.highlights.isEmpty || !$0.notes.isEmpty }
    }

    private static func query(_ url: URL, _ sql: String) throws -> [[String?]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw AppError(verbatim: String(localized: "Couldn’t open Apple Books’ highlights."))
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw AppError(verbatim: String(localized: "Apple Books’ highlights are in a format this app doesn’t know (\(message))."))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        let columns = sqlite3_column_count(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<columns).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
        return rows
    }

    // MARK: Matching

    /// Pairs imported books with books on your shelves, by title and author.
    static func match(_ imported: [ImportedBook], to library: [ShelfEntry]) -> [String: ShelfEntry] {
        var byTitle: [String: [ShelfEntry]] = [:]
        for entry in library {
            for key in titleKeys(entry.title) { byTitle[key, default: []].append(entry) }
        }
        var result: [String: ShelfEntry] = [:]
        for book in imported {
            let authors = authorTokens(book.author)
            for key in titleKeys(book.title) {
                let candidates = byTitle[key] ?? []
                if let hit = candidates.first(where: { authors.isEmpty || !authorTokens($0.author).isDisjoint(with: authors) }) {
                    result[book.id] = hit
                    break
                }
            }
        }
        return result
    }

    /// The full title and the one before any subtitle or series note,
    /// folded for case and accents.
    static func titleKeys(_ title: String) -> [String] {
        let noSeries = title.replacingOccurrences(of: #"\s*\([^()]*\)\s*$"#, with: "", options: .regularExpression)
        var keys = [fold(title), fold(noSeries)]
        if let colon = noSeries.firstIndex(where: { $0 == ":" || $0 == "—" }) {
            keys.append(fold(String(noSeries[..<colon])))
        }
        return keys.filter { !$0.isEmpty }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    static func authorTokens(_ author: String) -> Set<String> {
        Set(fold(author).split(separator: " ").map(String.init).filter { $0.count >= 3 })
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Merging

    /// Adds what's new to a note: highlights as quotes, notes as lines of text.
    static func merge(_ book: ImportedBook, into note: BookNote) -> (BookNote, added: Int) {
        var note = note
        var added = 0
        for quote in book.highlights where !note.quotes.contains(quote) {
            note.quotes.append(quote)
            added += 1
        }
        for line in book.notes where !note.text.contains(line) {
            note.text += (note.text.isEmpty ? "" : "\n") + line
            added += 1
        }
        return (note, added)
    }
}

// MARK: - Sheet

struct HighlightsImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: LibraryModel

    @State private var source: HighlightSource = .appleBooks
    @State private var books: [ImportedBook] = []
    @State private var matches: [String: ShelfEntry] = [:]
    @State private var chosen: Set<String> = []
    @State private var message: String?
    @State private var isWorking = false
    @State private var needsFolder = false

    var body: some View {
        VStack(spacing: 0) {
            GlassHeader {
                Text("Import Highlights")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .glassButton()
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("From", selection: $source) {
                        ForEach(HighlightSource.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    Button(source == .kindle ? String(localized: "Choose File…") : String(localized: "Read Highlights")) {
                        Task { await read() }
                    }
                    .disabled(isWorking)
                    if needsFolder {
                        Button("Choose Apple Books Folder…") { Task { await read(pickFolder: true) } }
                    }
                    if isWorking { ProgressView().controlSize(.small) }
                }
                Text(source == .kindle
                     ? String(localized: "Connect your Kindle and pick documents/My Clippings.txt.")
                     : String(localized: "Highlights and notes you made in Apple Books on this Mac. macOS may ask to let the app read them."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let message {
                    Text(message).font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            .padding(14)

            Divider()

            if books.isEmpty {
                Spacer()
                Text("Highlights you import become quotes in each book’s notes.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    let matched = books.filter { matches[$0.id] != nil }
                    let unmatched = books.filter { matches[$0.id] == nil }
                    if !matched.isEmpty {
                        Section("On your shelves") {
                            ForEach(matched) { book in
                                Toggle(isOn: Binding(
                                    get: { chosen.contains(book.id) },
                                    set: { if $0 { chosen.insert(book.id) } else { chosen.remove(book.id) } }
                                )) {
                                    row(book, entry: matches[book.id])
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    if !unmatched.isEmpty {
                        Section("Not on your shelves") {
                            ForEach(unmatched) { row($0, entry: nil).opacity(0.6) }
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(chosen.count) books selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Import") { Task { await importChosen() } }
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButton()
                    .disabled(chosen.isEmpty || isWorking)
            }
            .padding(12)
        }
        .frame(width: 560, height: 560)
        .onChange(of: source) { _ in
            books = []; matches = [:]; chosen = []; message = nil; needsFolder = false
        }
    }

    private func row(_ book: ImportedBook, entry: ShelfEntry?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry?.title ?? book.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(String(localized: "\(book.highlights.count) highlights, \(book.notes.count) notes")
                 + (book.author.isEmpty ? "" : " · \(book.author)"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func read(pickFolder: Bool = false) async {
        message = nil
        isWorking = true
        defer { isWorking = false }
        do {
            switch source {
            case .kindle:
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.plainText]
                panel.message = String(localized: "Choose “My Clippings.txt” from your Kindle’s documents folder.")
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let data = try Data(contentsOf: url)
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                books = Highlights.parseKindle(text)
            case .appleBooks:
                var folder = Highlights.appleBooksFolder
                if pickFolder {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = folder
                    panel.message = String(localized: "Choose Apple Books’ Documents folder, then Open.")
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    folder = url
                }
                let target = folder
                books = try await Task.detached { try Highlights.readAppleBooks(folder: target) }.value
                needsFolder = false
            }
        } catch {
            let denied = (error as NSError).domain == NSCocoaErrorDomain
                && [NSFileReadNoPermissionError, NSFileReadUnknownError].contains((error as NSError).code)
            if source == .appleBooks, denied || (error as NSError).code == NSFileReadNoSuchFileError {
                needsFolder = true
                message = String(localized: "macOS didn’t let the app read Apple Books. Choose its folder to allow it once, or turn on Full Disk Access for Goodreads in System Settings.")
            } else {
                message = error.localizedDescription
            }
            return
        }

        let library = model.shelves.flatMap { ShelfCache.read($0)?.entries ?? [] }
        matches = Highlights.match(books, to: library)
        chosen = Set(books.filter { matches[$0.id] != nil }.map(\.id))
        if books.isEmpty { message = String(localized: "No highlights found.") }
    }

    private func importChosen() async {
        isWorking = true
        defer { isWorking = false }
        var added = 0
        var bookCount = 0
        for book in books where chosen.contains(book.id) {
            guard let entry = matches[book.id] else { continue }
            let (note, count) = Highlights.merge(book, into: await BookNotes.note(for: entry.bookID))
            guard count > 0 else { continue }
            await BookNotes.save(note, for: entry.bookID)
            added += count
            bookCount += 1
        }
        model.status = .init(text: String(localized: "Imported \(added) highlights and notes into \(bookCount) books."),
                             isError: false)
        dismiss()
    }
}
