import Foundation

/// Book discovery — search and "more by this author" — via the Google Books
/// API. Goodreads' own autocomplete doesn't report language or publisher, and
/// scraping its book pages for language turned out too unreliable; Google
/// Books reports both cleanly for virtually every catalogued edition, and
/// hands back an ISBN we can use to find the matching Goodreads book when one
/// is needed (see `GoodreadsLookup`).
enum GoogleBooksClient {

    static func search(_ query: String,
                       language: BookLanguage = .any,
                       sortNewest: Bool = false,
                       subject: String = "") async throws -> [Book] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // An ISBN only finds anything written as "isbn:…"; Goodreads knows
        // editions Google doesn't, so it's asked too when Google has none.
        if let isbn = ISBN.normalized(trimmed) {
            if let found = try? await volumes(q: "isbn:\(isbn)"), !found.isEmpty { return found }
            if let book = await goodreadsBook(isbn: isbn) { return [book] }
            return []
        }

        var q = trimmed
        let subjectTerm = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if !subjectTerm.isEmpty { q += " subject:\"\(subjectTerm)\"" }

        do {
            return try await volumes(q: q, langRestrict: language.restrictCode, sortNewest: sortNewest)
        } catch let httpError as GoogleBooksHTTPError {
            // The free shared tier (no personal key) stays exhausted — it's
            // shared across every caller of this app on the internet — which
            // turns search, the one thing the app is built around, into a
            // quota error on a fresh install. Fall back to Goodreads' own
            // unauthenticated autocomplete instead of surfacing that,
            // trading away language/publisher/ISBN data for a search that
            // actually returns something. Only when there's no key to blame
            // instead: a *personal* key failing this way (wrong API enabled,
            // bad key) is a real problem that a silent fallback would hide,
            // and this only catches an HTTP-status failure in the first
            // place — a genuinely malformed response still surfaces directly.
            // Google's own outages (5xx) fall back too, key or not.
            guard httpError.apiKeyWasEmpty || httpError.status >= 500 else { throw httpError }
            return try await SearchClient.search(trimmed)
        }
    }

    /// The Goodreads edition with this ISBN, as a search result.
    static func goodreadsBook(isbn: String) async -> Book? {
        guard let bookID = await GoodreadsLookup.bookID(isbn: isbn),
              let detail = try? await GoodreadsBookPage.fetch(bookID: bookID),
              let about = detail.about, let title = about.title else { return nil }
        return Book(id: isbn, title: title, author: about.authorName ?? "", coverURL: about.coverURL,
                    rating: about.averageRating.map { String(format: "%.1f", $0) }, publisher: about.publisher,
                    isbn: isbn, goodreadsID: bookID, language: detail.language, description: about.synopsis,
                    pageCount: detail.pageCount,
                    publishedDate: about.published.map { $0.formatted(.dateTime.year()) })
    }

    /// Used by suggestions to find more books by an author already read.
    static func searchByAuthor(_ author: String) async throws -> [Book] {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let key = trimmed.lowercased()
        if let hit = await DataCache.shared.read([Book].self, "author-search", key,
                                                 ttl: DataCache.TTL.authorSearch), !hit.isStale {
            return hit.value
        }
        let books = try await volumes(q: "inauthor:\"\(trimmed)\"")
        await DataCache.shared.write(books, "author-search", key)
        return books
    }

    /// An author's most recently published books, for "New from your
    /// authors". Cached for a day.
    static func newestByAuthor(_ author: String) async throws -> [Book] {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let key = trimmed.lowercased()
        if let hit = await DataCache.shared.read([Book].self, "author-newest", key,
                                                 ttl: DataCache.TTL.newReleases), !hit.isStale {
            return hit.value
        }
        let books = try await volumes(q: "inauthor:\"\(trimmed)\"", sortNewest: true)
        await DataCache.shared.write(books, "author-newest", key)
        return books
    }

    /// One book's Google Books record, for details Goodreads didn't give:
    /// by ISBN when there is one, otherwise by title and author. Cached for a
    /// week; nil when nothing matches closely enough.
    static func details(isbn: String?, title: String, author: String,
                        language: String? = Bundle.main.preferredLocalizations.first) async -> Book? {
        let cleanTitle = title.replacingOccurrences(of: #"\s*\([^()]*#[^()]*\)\s*$"#, with: "", options: .regularExpression)
        let key = isbn.map { "isbn:\($0)" } ?? "\(cleanTitle)|\(author)".lowercased()
        if let hit = await DataCache.shared.read(Book?.self, "google-book", key, ttl: 7 * 24 * 3600), !hit.isStale {
            return hit.value
        }
        var found: Book?
        if let isbn, !isbn.isEmpty {
            found = try? await volumes(q: "isbn:\(isbn)", maxResults: 3).first
        }
        if found == nil {
            let byline = author.isEmpty ? "" : " inauthor:\"\(author.split(separator: ",").first.map(String.init) ?? author)\""
            let candidates = (try? await volumes(q: "intitle:\"\(cleanTitle)\"\(byline)", maxResults: 10)) ?? []
            found = bestMatch(candidates, title: cleanTitle, language: language)
        }
        await DataCache.shared.write(found, "google-book", key)
        return found
    }

    enum TitleLookup: Sendable { case found(String), none, failed }

    /// The title Google Books has for this exact ISBN. `.failed` when Google
    /// couldn't be asked (no key, out of quota, offline), so it's tried again.
    static func title(isbn: String) async -> TitleLookup {
        guard !isbn.isEmpty else { return .none }
        do {
            let found = try await volumes(q: "isbn:\(isbn)", maxResults: 1).first
            guard let title = found?.title, !title.isEmpty else { return .none }
            return .found(title)
        } catch {
            return .failed
        }
    }

    /// The candidate whose title matches, preferring one in `language`, then
    /// one with a description.
    static func bestMatch(_ candidates: [Book], title: String, language: String? = nil) -> Book? {
        let wanted = Suggestions.normalizedTitle(title)
        let exact = candidates.filter { Suggestions.normalizedTitle($0.title) == wanted }
        // A longer title only counts as a subtitle ("Dune: Deluxe Edition"),
        // never as another book that starts the same ("Dune Messiah").
        let subtitled = candidates.filter { candidate in
            guard let cut = candidate.title.firstIndex(where: { ":(—–".contains($0) }) else { return false }
            return Suggestions.normalizedTitle(String(candidate.title[..<cut])) == wanted
        }
        func hasText(_ book: Book) -> Bool { !(book.description ?? "").isEmpty }
        func inLanguage(_ book: Book) -> Bool {
            guard let language, let bookLanguage = book.language else { return false }
            return bookLanguage.lowercased().hasPrefix(language.lowercased())
        }
        for group in [exact, subtitled] where !group.isEmpty {
            return group.first { inLanguage($0) && hasText($0) } ?? group.first(where: inLanguage)
                ?? group.first(where: hasText) ?? group.first
        }
        return nil
    }

    private static func volumes(q: String,
                                langRestrict: String? = nil,
                                sortNewest: Bool = false,
                                maxResults: Int = 20) async throws -> [Book] {
        var query = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "orderBy", value: sortNewest ? "newest" : "relevance")
        ]
        if let langRestrict {
            query.append(URLQueryItem(name: "langRestrict", value: langRestrict))
        }
        let data = try await get("volumes", query)
        let decoded: VolumesResponse
        do {
            decoded = try JSONDecoder().decode(VolumesResponse.self, from: data)
        } catch {
            throw AppError("Couldn't read Google Books' response.")
        }
        return (decoded.items ?? []).compactMap(book(from:))
    }

    // MARK: Series

    /// A series' name and its books, in order, from Google Books. Books
    /// without a number in the series (box sets, extras) are left out.
    static func series(id: String) async throws -> (title: String?, books: [Book]) {
        struct Info: Decodable { struct Series: Decodable { let title: String? }; let series: [Series]? }
        struct Membership: Decodable { let member: [Item]?; let nextPageToken: String? }
        let title = (try? JSONDecoder().decode(Info.self, from: try await get("series/get", [URLQueryItem(name: "series_id", value: id)])))?
            .series?.first?.title
        var books: [Book] = []
        var token: String?
        for _ in 0..<5 {
            var query = [URLQueryItem(name: "series_id", value: id), URLQueryItem(name: "page_size", value: "40")]
            if let token { query.append(URLQueryItem(name: "page_token", value: token)) }
            let page = try JSONDecoder().decode(Membership.self, from: try await get("series/membership/get", query))
            books += (page.member ?? []).compactMap(book(from:))
            token = page.nextPageToken
            if token == nil { break }
        }
        var byNumber: [Double: Book] = [:]
        for book in books where book.seriesID == id {
            guard let number = book.seriesNumber, number > 0 else { continue }
            if byNumber[number] == nil { byNumber[number] = book }
        }
        return (title, byNumber.values.sorted { ($0.seriesNumber ?? 0) < ($1.seriesNumber ?? 0) })
    }

    /// Which series a book is in, from any of its Google Books editions —
    /// often only the ebook edition says. Cached: a month when it isn't in
    /// one, for good when it is.
    static func seriesOf(isbn: String?, title: String, author: String) async -> Book? {
        let cleanTitle = title.replacingOccurrences(of: #"\s*\([^()]*#[^()]*\)\s*$"#, with: "", options: .regularExpression)
        let key = "\(isbn ?? "")|\(cleanTitle)|\(author)".lowercased()
        if let hit = await DataCache.shared.read(Book?.self, "google-series-of", key, ttl: 30 * 24 * 3600),
           hit.value != nil || !hit.isStale {
            return hit.value
        }
        var candidates: [Book] = []
        do {
            if let isbn, !isbn.isEmpty { candidates += try await volumes(q: "isbn:\(isbn)", maxResults: 3) }
            if !candidates.contains(where: { $0.seriesID != nil }) {
                let byline = author.isEmpty ? "" : " inauthor:\"\(author.split(separator: ",").first.map(String.init) ?? author)\""
                let found = try await volumes(q: "intitle:\"\(cleanTitle)\"\(byline)", maxResults: 20)
                let wanted = Suggestions.normalizedTitle(cleanTitle)
                candidates += found.filter { candidate in
                    let name = Suggestions.normalizedTitle(candidate.title)
                    return name == wanted || name.hasPrefix(wanted + " ")
                }
            }
        } catch {
            return nil      // not saved, so it's asked again next time
        }
        let found = candidates.first { $0.seriesID != nil && $0.seriesNumber != nil }
        await DataCache.shared.write(found, "google-series-of", key)
        return found
    }

    /// A Google Books API call, with your key when there is one.
    private static func get(_ path: String, _ query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/\(path)")!
        components.queryItems = query

        // The free shared tier stays exhausted (it's shared across every
        // caller with no key), so a personal key set in Settings goes on
        // every request once there is one.
        let apiKey = await Preferences.shared.googleBooksAPIKey.trimmingCharacters(in: .whitespaces)
        if !apiKey.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "key", value: apiKey))
        }

        var request = URLRequest(url: components.url!)
        request.setValue("GoodreadsGUI/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
                ?? String(localized: "Google Books returned HTTP \(http.statusCode).")
            let hint = apiKey.isEmpty ? String(localized: " Add a free API key in Settings — the shared tier is out of quota.") : ""
            throw GoogleBooksHTTPError(message: message + hint, apiKeyWasEmpty: apiKey.isEmpty, status: http.statusCode)
        }

        return data
    }

    private static func book(from item: Item) -> Book? {
        let info = item.volumeInfo
        guard let title = info.title else { return nil }

        let isbn13 = info.industryIdentifiers?.first { $0.type == "ISBN_13" }?.identifier
        let isbn10 = info.industryIdentifiers?.first { $0.type == "ISBN_10" }?.identifier
        let isbn = isbn13 ?? isbn10
        let id = isbn ?? "gb:\(item.id)"

        let cover = info.imageLinks?.thumbnail.map {
            $0.replacingOccurrences(of: "http://", with: "https://")
        }

        return Book(
            id: id,
            title: title,
            author: (info.authors ?? []).joined(separator: ", ").ifEmpty(String(localized: "Unknown author")),
            coverURL: cover.flatMap(URL.init(string:)),
            rating: info.averageRating.map { String(format: "%.1f", $0) },
            publisher: info.publisher,
            isbn: isbn,
            language: info.language,
            description: info.description,
            pageCount: info.pageCount,
            publishedDate: info.publishedDate,
            categories: info.categories,
            seriesID: info.seriesInfo?.volumeSeries?.first?.seriesId,
            seriesNumber: info.seriesInfo?.volumeSeries?.first?.orderNumber.map(Double.init)
                ?? info.seriesInfo?.bookDisplayNumber.flatMap { Double($0) }
        )
    }

    /// An HTTP-level failure from the `volumes` endpoint specifically —
    /// distinguished from a decode failure (a real bug worth seeing
    /// directly) so `search(_:)` can tell "Google rejected this request"
    /// apart from "the response didn't parse", and only treat the former as
    /// grounds for falling back to `SearchClient`.
    private struct GoogleBooksHTTPError: LocalizedError {
        let message: String
        let apiKeyWasEmpty: Bool
        var status = 0
        var errorDescription: String? { message }
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorDetail
        struct ErrorDetail: Decodable { let message: String? }
    }

    private struct VolumesResponse: Decodable {
        let items: [Item]?
    }

    private struct Item: Decodable {
        let id: String
        let volumeInfo: VolumeInfo
    }

    private struct VolumeInfo: Decodable {
        let title: String?
        let authors: [String]?
        let publisher: String?
        let language: String?
        let averageRating: Double?
        let industryIdentifiers: [Identifier]?
        let imageLinks: ImageLinks?
        let description: String?
        let pageCount: Int?
        let publishedDate: String?
        let categories: [String]?
        let seriesInfo: SeriesInfo?
    }

    private struct SeriesInfo: Decodable {
        struct Member: Decodable { let seriesId: String?; let orderNumber: Int? }
        let bookDisplayNumber: String?
        let volumeSeries: [Member]?
    }

    private struct Identifier: Decodable {
        let type: String
        let identifier: String
    }

    private struct ImageLinks: Decodable {
        let thumbnail: String?
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
