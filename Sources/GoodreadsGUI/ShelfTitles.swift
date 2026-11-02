import Foundation

/// Clean titles for your books. Goodreads titles are whatever the edition's
/// librarian typed — "Feliz ano velho de Marcelo Rubens Paiva pela Mandarim
/// 1996 E" — so the app shows Google Books' title for the same ISBN when
/// there's a key, and otherwise trims the author and publisher off titles
/// that carry them.
enum ShelfTitles {

    /// Book id → Google's title; "" when Google was asked and had none.
    nonisolated(unsafe) private static var known: [String: String]?
    private static let lock = NSLock()

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoodreadsGUI/cache/titles.json")
    }

    private static func withMap<T>(_ body: (inout [String: String]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        if known == nil {
            known = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        }
        return body(&known!)
    }

    // MARK: Showing

    /// The title to show for `entry`.
    static func title(for entry: ShelfEntry) -> String {
        if let google = withMap({ $0[entry.bookID] }), !google.isEmpty { return frontArticle(google) }
        return tidy(entry.title, author: entry.author)
    }

    static func apply(_ entries: [ShelfEntry]) -> [ShelfEntry] {
        entries.map { entry in
            let shown = title(for: entry)
            return shown == entry.title ? entry : entry.withTitle(shown)
        }
    }

    /// Titles that carry the author or publisher after them: "X de Author…",
    /// "X by Author…", "X - Author…". Cut at the author's name, keeping any
    /// "(Series, #1)" Goodreads added.
    static func tidy(_ title: String, author: String) -> String {
        let names = author.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let full = names.count == 2 ? "\(names[1]) \(names[0])" : author
        guard full.count >= 4 else { return title }
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let wanted = full.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let lastName = wanted.split(separator: " ").last.map(String.init) ?? wanted
        for joiner in [" de ", " by ", " por ", " von ", " - ", " — ", ", "] {
            for name in [wanted, lastName] where name.count >= 4 {
                guard let range = folded.range(of: joiner + name) else { continue }
                // "Cartas de Fernando Pessoa" is a real title; only cut after
                // "de" or a comma when more follows the name (publisher, year…).
                let rest = folded[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if [" de ", ", ", " von ", " por "].contains(joiner), rest.isEmpty || rest.hasPrefix("#") { continue }
                let cut = folded.distance(from: folded.startIndex, to: range.lowerBound)
                let head = String(title.prefix(cut)).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                guard head.count >= 2 else { continue }
                if let series = title.range(of: #"\s*\([^()]*#[^()]*\)\s*$"#, options: .regularExpression),
                   series.lowerBound > title.index(title.startIndex, offsetBy: cut) {
                    return head + " " + title[series].trimmingCharacters(in: .whitespaces)
                }
                return head
            }
        }
        return title
    }

    /// Catalogue-style titles put the article last: "Gato Malhado, O" →
    /// "O Gato Malhado".
    static func frontArticle(_ title: String) -> String {
        let articles = ["O", "A", "Os", "As", "Um", "Uma", "The", "A", "An", "El", "La", "Los", "Las", "Le", "Les", "Il", "Lo", "Der", "Die", "Das"]
        guard let comma = title.range(of: ", ", options: .backwards) else { return title }
        let tail = String(title[comma.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard articles.contains(where: { $0.caseInsensitiveCompare(tail) == .orderedSame }) else { return title }
        return tail.prefix(1).uppercased() + tail.dropFirst() + " " + title[..<comma.lowerBound]
    }

    // MARK: Fetching

    /// Your books with an ISBN that Google hasn't been asked about yet.
    static func missing(_ entries: [ShelfEntry]) -> [ShelfEntry] {
        withMap { map in entries.filter { ($0.isbn13 ?? $0.isbn) != nil && map[$0.bookID] == nil } }
    }

    static func save(_ title: String?, for bookID: String) {
        let data: Data? = withMap { map in
            map[bookID] = title.map { frontArticle($0.trimmingCharacters(in: .whitespaces)) } ?? ""
            return try? JSONEncoder().encode(map)
        }
        guard let data else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Asks Google Books for each ISBN, two at a time. Only titles found by
    /// the book's own ISBN are used, never a guess by title.
    static func fetch(_ entries: [ShelfEntry]) async -> Bool {
        let todo = missing(entries)
        guard !todo.isEmpty else { return false }
        var changed = false
        var index = 0
        while index < todo.count, !Task.isCancelled {
            let batch = todo[index..<min(index + 2, todo.count)]
            index += 2
            await withTaskGroup(of: (String, String?, Bool).self) { group in
                for entry in batch {
                    group.addTask {
                        let isbn = entry.isbn13 ?? entry.isbn ?? ""
                        switch await GoogleBooksClient.title(isbn: isbn) {
                        case .found(let title): return (entry.bookID, title, true)
                        case .none: return (entry.bookID, nil, true)
                        case .failed: return (entry.bookID, nil, false)
                        }
                    }
                }
                for await (bookID, title, answered) in group where answered {
                    save(title, for: bookID)
                    if title != nil { changed = true }
                }
            }
        }
        return changed
    }

    /// Forgets every Google title (Settings → Clear Cache).
    static func clear() {
        withMap { $0 = [:] }
        try? FileManager.default.removeItem(at: file)
    }
}

extension ShelfEntry {
    func withTitle(_ title: String) -> ShelfEntry {
        ShelfEntry(id: id, bookID: bookID, reviewID: reviewID, title: title, author: author,
                   coverURLString: coverURLString, rating: rating, dateRead: dateRead, dateAdded: dateAdded,
                   isbn: isbn, isbn13: isbn13, progress: progress)
    }
}
