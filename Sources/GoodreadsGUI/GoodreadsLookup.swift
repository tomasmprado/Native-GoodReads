import Foundation

/// Bridges a Google Books result back to a Goodreads book id, so shelving,
/// rating, progress and reviews — everything that needs *your* Goodreads
/// account — keep working against the same `ShelfService` calls as before.
enum GoodreadsLookup {

    /// Resolves in this order: an id the book already carries (shelf entries
    /// always have one), then its ISBN via Goodreads' legacy redirect, then a
    /// title/author search as a last resort for the rare item with no ISBN.
    static func bookID(for book: Book) async throws -> String {
        if let known = book.goodreadsID { return known }

        if let isbn = book.isbn {
            if let cached = await cache.read(isbn) { return cached }
            if let resolved = try? await byISBN(isbn) {
                await cache.write(isbn: isbn, bookID: resolved)
                return resolved
            }
        }

        return try await byTitleAndAuthor(title: book.title, author: book.author)
    }

    /// `/book/isbn/<isbn>` 301-redirects to `/book/show/<id>-slug`, publicly —
    /// no session or cookies needed, so this is a plain request off to the
    /// side of the shared web view.
    private static func byISBN(_ isbn: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.goodreads.com/book/isbn/\(isbn)")!)
        request.setValue("GoodreadsGUI/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let landed = response.url?.absoluteString, let id = bookID(fromURL: landed) else {
            throw AppError("No Goodreads edition found for ISBN \(isbn).")
        }
        return id
    }

    private static func byTitleAndAuthor(title: String, author: String) async throws -> String {
        guard let found = try await SearchClient.search("\(title) \(author)").first else {
            throw AppError("Couldn't find “\(title)” on Goodreads.")
        }
        return found.id
    }

    private static func bookID(fromURL urlString: String) -> String? {
        guard let range = urlString.range(of: #"/book/show/(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return urlString[range].replacingOccurrences(of: "/book/show/", with: "")
    }

    // MARK: - Cache

    private static let cache = Cache()

    /// Same shape as `ShelfCache`: a JSON file under Application Support,
    /// loaded once. Avoids re-hitting the redirect for books used repeatedly
    /// (progress updates, reopening a detail page, etc).
    ///
    /// An actor, not a plain `enum` with a static `var` — `bookID(for:)` can
    /// be called concurrently for several search results at once, and a bare
    /// static mutable dictionary would be a data race under Swift
    /// concurrency checking.
    private actor Cache {
        private static let file: URL = {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = base.appendingPathComponent("GoodreadsGUI", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("isbn-lookup.json")
        }()

        private var memory: [String: String]

        init() {
            if let data = try? Data(contentsOf: Cache.file),
               let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                memory = decoded
            } else {
                memory = [:]
            }
        }

        func read(_ isbn: String) -> String? { memory[isbn] }

        func write(isbn: String, bookID: String) {
            memory[isbn] = bookID
            guard let data = try? JSONEncoder().encode(memory) else { return }
            try? data.write(to: Cache.file, options: .atomic)
        }
    }
}
