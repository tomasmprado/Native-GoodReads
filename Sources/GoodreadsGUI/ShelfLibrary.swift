import Foundation

struct ShelfEntryEnvelope: Decodable {
    let ok: Bool
    let rows: [ShelfLibrary.Row]?
    let pages: Int?
    let error: String?
}

/// Reads shelves by fetching `/review/list` from inside a loaded page and
/// parsing the HTML with DOMParser. No navigation, so several pages can be in
/// flight at once and nothing collides with other work.
enum ShelfLibrary {

    static let perPage = 100
    static let maxPages = 25       // 2500 books; a safety stop, not a real limit
    private static let pageConcurrency = 4

    struct Row: Decodable {
        let bookId: String
        let reviewId: String?
        let title: String
        let author: String
        let cover: String?
        let rating: Int?
        let dateRead: String?
        let dateAdded: String?
    }

    /// Fetches page 1 to learn the page count, then the rest `pageConcurrency`
    /// at a time — orchestrated from Swift, rather than one opaque JS call
    /// that pools internally, so `onPage` can report real per-page progress
    /// instead of firing once at the very end.
    ///
    /// `ofUser` browses someone else's shelf instead of the signed-in user's
    /// own (`/review/list/<id>` rather than the implicit `/review/list`) —
    /// same template, same rating column, so a friend's shelf reuses this
    /// unchanged.
    static func load(_ shelf: Shelf,
                     ofUser userID: String? = nil,
                     onPage: @MainActor (Int, Int) -> Void = { _, _ in }) async throws -> [ShelfEntry] {
        let session = WebSession.shared
        // Always present, even for the signed-in user's own shelf — the JS
        // side references `userId` unconditionally, and an omitted argument
        // key leaves it undeclared rather than merely falsy.
        let userIdArg = userID ?? ""

        let firstRaw = try await session.exclusive { () -> String in
            try await session.ensureOnGoodreads()
            return try await session.evaluate(
                firstPageScript,
                arguments: ["shelf": shelf.name, "perPage": perPage, "maxPages": maxPages, "userId": userIdArg],
                label: "load shelf \(shelf.name)\(userID.map { " for \($0)" } ?? "") page 1"
            )
        }

        let firstEnvelope = try decodeEnvelope(firstRaw)
        guard firstEnvelope.ok, var rows = firstEnvelope.rows else {
            throw AppError(firstEnvelope.error ?? "The shelf page couldn't be read.")
        }
        let pages = firstEnvelope.pages ?? 1
        await onPage(rows.count, pages)

        if pages > 1 {
            var completed = rows.count
            try await withThrowingTaskGroup(of: [Row].self) { group in
                var next = 2
                func addNext() {
                    guard next <= pages else { return }
                    let page = next
                    next += 1
                    group.addTask {
                        // Fetch-based (WebScripts.dom), independent of
                        // whatever page is currently loaded — safe to run
                        // concurrently, unlocked.
                        let raw = try await session.evaluate(
                            pageScript,
                            arguments: ["shelf": shelf.name, "page": page, "perPage": perPage, "userId": userIdArg],
                            label: "load shelf \(shelf.name) page \(page)"
                        )
                        let envelope = try decodeEnvelope(raw)
                        guard envelope.ok, let pageRows = envelope.rows else {
                            throw AppError(envelope.error ?? "Page \(page) of the shelf couldn't be read.")
                        }
                        return pageRows
                    }
                }
                for _ in 0..<min(pageConcurrency, pages - 1) { addNext() }
                while let pageRows = try await group.next() {
                    rows.append(contentsOf: pageRows)
                    completed += pageRows.count
                    await onPage(completed, pages)
                    addNext()
                }
            }
        }

        var seen = Set<String>()
        return rows.compactMap { row in
            guard !row.bookId.isEmpty, seen.insert(row.bookId).inserted else { return nil }
            return ShelfEntry(
                id: row.reviewId ?? row.bookId,
                bookID: row.bookId,
                reviewID: row.reviewId,
                title: row.title,
                author: row.author,
                coverURLString: row.cover,
                rating: row.rating,
                dateRead: row.dateRead?.isEmpty == false ? row.dateRead : nil,
                progress: nil
            )
        }
    }

    private static func decodeEnvelope(_ raw: String) throws -> ShelfEntryEnvelope {
        guard let data = raw.data(using: .utf8) else {
            throw AppError("Couldn't read the shelf page.")
        }
        return try JSONDecoder().decode(ShelfEntryEnvelope.self, from: data)
    }

    /// Scrapes the shelf list out of the My Books sidebar, so custom shelves
    /// show up without being hardcoded.
    static func discoverShelves() async throws -> [Shelf] {
        let session = WebSession.shared

        let raw = try await session.exclusive { () -> String in
            try await session.ensureOnGoodreads()
            return try await session.evaluate(shelvesScript, label: "discover shelves")
        }

        guard let data = raw.data(using: .utf8) else {
            throw AppError("Couldn't read the shelf list.")
        }

        let envelope = try JSONDecoder().decode(ShelfListEnvelope.self, from: data)
        guard envelope.ok, let found = envelope.rows else {
            throw AppError(envelope.error ?? "The shelf list couldn't be read.")
        }

        // Drop pseudo-shelves, then collapse to-read/want-to-read duplicates,
        // keeping whichever entry actually carried a count.
        var byName: [String: Shelf] = [:]
        var order: [String] = []

        for row in found where !Shelf.isPseudo(row.name) {
            let shelf = Shelf.fromSlug(row.name, count: row.count)
            if let existing = byName[shelf.name] {
                byName[shelf.name] = Shelf(name: shelf.name,
                                           label: shelf.label,
                                           count: shelf.count ?? existing.count)
            } else {
                byName[shelf.name] = shelf
                order.append(shelf.name)
            }
        }

        var shelves = order.compactMap { byName[$0] }

        // Built-ins always appear first and always appear, even when empty.
        for builtIn in Shelf.builtIn.reversed() {
            if let index = shelves.firstIndex(where: { $0.name == builtIn.name }) {
                let existing = shelves.remove(at: index)
                shelves.insert(existing, at: 0)
            } else {
                shelves.insert(builtIn, at: 0)
            }
        }
        return shelves
    }

    private struct ShelfListEnvelope: Decodable {
        let ok: Bool
        let rows: [ShelfRow]?
        let error: String?
    }

    private struct ShelfRow: Decodable {
        let name: String
        let count: Int?
    }

    // MARK: - Scripts

    private static let firstPageScript = WebScripts.dom + """
    try {
        const doc = await getDoc(shelfURL(shelf, 1, perPage, null, userId));
        const rows = parseRows(doc);
        const pages = Math.min(lastPageNumber(doc), maxPages);
        return JSON.stringify({ ok: true, rows: rows, pages: pages });
    } catch (e) {
        return JSON.stringify({ ok: false, error: 'shelf: ' + (e && e.message ? e.message : String(e)) });
    }
    """

    private static let pageScript = WebScripts.dom + """
    try {
        const doc = await getDoc(shelfURL(shelf, page, perPage, null, userId));
        const rows = parseRows(doc);
        return JSON.stringify({ ok: true, rows: rows });
    } catch (e) {
        return JSON.stringify({ ok: false, error: 'shelf: ' + (e && e.message ? e.message : String(e)) });
    }
    """

    private static let shelvesScript = WebScripts.dom + """
    try {
        const doc = await getDoc('/review/list');
        const seen = new Map();

        for (const link of doc.querySelectorAll('a[href*="shelf="]')) {
            const href = link.getAttribute('href') || '';
            const match = href.match(/[?&]shelf=([^&]+)/);
            if (!match) continue;

            // A stray % in a shelf name makes decodeURIComponent throw.
            let name = match[1];
            try { name = decodeURIComponent(name); } catch (e) { /* keep raw */ }

            if (!name || name === 'ALL' || name.charAt(0) === '#') continue;

            const countMatch = (link.textContent || '').match(/\\((\\d[\\d,]*)\\)/);
            const count = countMatch ? parseInt(countMatch[1].replace(/,/g, ''), 10) : null;

            if (!seen.has(name) || (count !== null && seen.get(name) === null)) {
                seen.set(name, count);
            }
        }

        const rows = [];
        seen.forEach((count, name) => rows.push({ name: name, count: count }));
        return JSON.stringify({ ok: true, rows: rows });
    } catch (e) {
        return JSON.stringify({ ok: false, error: 'shelf list: ' + (e && e.message ? e.message : String(e)) });
    }
    """
}
