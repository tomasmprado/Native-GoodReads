import Foundation

/// Reads a Goodreads book page for the detail view — its edition language and
/// its community reviews. The page is public, so this is a plain unauthenticated
/// fetch, no WKWebView or session cookies involved.
///
/// Goodreads embeds a Next.js `__NEXT_DATA__` script with the same GraphQL
/// cache the live page hydrates from — `props.pageProps.apolloState`, a flat
/// map of `"<Type>:<id>"` keys to entities, with `{"__ref": "..."}` pointers
/// between them. `ROOT_QUERY.getReviews` holds the ordered review list.
enum GoodreadsBookPage {

    struct Detail: Codable {
        let language: String?
        let authorURL: URL?
        let reviews: [Review]
        // Absent from book pages cached before 2.3.
        var pageCount: Int? = nil
        var genres: [String]? = nil
        var series: GoodreadsSeries.Ref? = nil
        // Absent from book pages cached before 2.6.
        var about: About? = nil
        /// The work all editions share — for "Readers also enjoyed". Absent before 3.1.
        var workID: String? = nil
    }

    /// What Book Details shows about the book itself.
    struct About: Codable, Equatable {
        var title: String?
        var authorName: String?
        var authorURL: URL?
        var coverURL: URL?
        /// The synopsis, as plain text with paragraph breaks.
        var synopsis: String?
        var publisher: String?
        var format: String?
        /// This edition's publication date.
        var published: Date?
        /// When the work first came out, if earlier.
        var firstPublished: Date?
        var originalTitle: String?
        var isbn: String?
        var isbn13: String?
        var averageRating: Double?
        var ratingsCount: Int?
        /// Ratings by stars, 1★ first.
        var ratingsByStars: [Int]?
        var reviewsCount: Int?
        var contributors: [Contributor] = []
        var awards: [Award] = []
        var characters: [String] = []
        var places: [String] = []
    }

    struct Contributor: Codable, Equatable, Hashable {
        let name: String
        let role: String
    }

    struct Award: Codable, Equatable, Hashable {
        let name: String
        let year: Int?
        let won: Bool
    }

    struct Review: Identifiable, Codable {
        let id: String
        let reviewerName: String
        let reviewerAvatarURL: URL?
        let rating: Int?
        let text: String
        let likeCount: Int?
        /// The reviewer's profile — or their author page, for authors. Absent before 2.8.
        var reviewerURL: URL? = nil
        var reviewerIsAuthor: Bool? = nil
        var reviewerFollowers: Int? = nil
    }

    static func fetch(bookID: String) async throws -> Detail {
        var request = URLRequest(url: URL(string: "https://www.goodreads.com/book/show/\(bookID)")!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        var detail: Detail?
        var firstError: Error?
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AppError("Goodreads returned HTTP \(http.statusCode).")
            }
            guard let html = String(data: data, encoding: .utf8) else {
                throw AppError("Couldn't read the book page.")
            }
            detail = try parse(html: html, bookID: bookID)
        } catch {
            firstError = error
        }
        // Goodreads' bot protection often answers a plain request with an
        // empty page (HTTP 202). The same page fetched from inside the
        // signed-in web view gets through.
        if detail == nil, let html = try? await htmlViaSession(bookID: bookID), !html.isEmpty {
            detail = try? parse(html: html, bookID: bookID)
        }
        guard let detail else { throw firstError ?? AppError("Couldn't read the book page.") }
        // Kept, so the bingo, the soundtrack and the suggestions can read it later.
        await DataCache.shared.write(detail, "book-page", bookID)
        await BookExtras.save(BookExtras(pages: detail.pageCount, genres: detail.genres ?? [],
                                           rating: detail.about?.averageRating,
                                           ratingsCount: detail.about?.ratingsCount), for: bookID)
        return detail
    }

    @MainActor
    private static func htmlViaSession(bookID: String) async throws -> String {
        let session = WebSession.shared
        guard session.isSignedIn else { return "" }
        return try await session.exclusive { () -> String in
            try await session.ensureOnGoodreads()
            return try await session.evaluate(
                """
                const response = await fetch('/book/show/' + encodeURIComponent(bookID), { credentials: 'include' });
                if (!response.ok) return '';
                return await response.text();
                """,
                arguments: ["bookID": bookID],
                label: "book page \(bookID) (in session)"
            )
        }
    }

    /// Everything the app reads from a book page's HTML — no network, so
    /// tests can run it against a saved page.
    static func parse(html: String, bookID: String) throws -> Detail {
        guard let apollo = apolloState(from: html) else {
            throw AppError("Couldn't find this book's data on the page.")
        }
        let book = bookEntity(bookID: bookID, in: apollo)
        let details = book?["details"] as? [String: Any]

        return Detail(
            language: ((details?["language"] as? [String: Any])?["name"] as? String)?.lowercased(),
            authorURL: authorURL(from: html),
            reviews: reviews(from: apollo),
            pageCount: (details?["numPages"] as? Int).flatMap { $0 > 0 ? $0 : nil },
            genres: genres(of: book),
            series: series(of: book, in: apollo),
            about: about(of: book, in: apollo, html: html),
            workID: workID(of: book, in: apollo)
        )
    }

    private static func about(of book: [String: Any]?, in apollo: [String: Any], html: String) -> About? {
        guard let book else { return nil }
        let details = book["details"] as? [String: Any] ?? [:]
        let work = ((book["work"] as? [String: Any])?["__ref"] as? String).flatMap { apollo[$0] as? [String: Any] }
        let workDetails = work?["details"] as? [String: Any] ?? [:]
        let stats = work?["stats"] as? [String: Any] ?? [:]

        func text(_ value: Any?) -> String? {
            guard let string = value as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func date(_ value: Any?) -> Date? {
            guard let millis = (value as? NSNumber)?.doubleValue else { return nil }
            return Date(timeIntervalSince1970: millis / 1000)
        }
        func names(_ value: Any?) -> [String] {
            (value as? [[String: Any]] ?? []).compactMap { text($0["name"]) }
        }

        var about = About()
        about.title = text(book["titleComplete"]) ?? text(book["title"])
        about.coverURL = text(book["imageUrl"]).flatMap(URL.init(string:))
        about.authorName = contributorName(book["primaryContributorEdge"] as? [String: Any], in: apollo)
            ?? authorName(fromJSONLD: html)
        if let ref = ((book["primaryContributorEdge"] as? [String: Any])?["node"] as? [String: Any])?["__ref"] as? String,
           let link = (apollo[ref] as? [String: Any])?["webUrl"] as? String {
            about.authorURL = URL(string: link)
        }
        about.synopsis = text(book["description"]).map(plainText(fromHTML:)).flatMap { $0.isEmpty ? nil : $0 }
        about.publisher = text(details["publisher"])
        about.format = text(details["format"])
        about.published = date(details["publicationTime"])
        if let first = date(workDetails["publicationTime"]),
           about.published.map({ first < $0.addingTimeInterval(-366 * 86400) }) ?? true {
            about.firstPublished = first
        }
        about.originalTitle = text(workDetails["originalTitle"]).flatMap { original in
            Suggestions.normalizedTitle(original) == Suggestions.normalizedTitle(about.title ?? "") ? nil : original
        }
        about.isbn = text(details["isbn"])
        about.isbn13 = text(details["isbn13"])
        about.averageRating = (stats["averageRating"] as? NSNumber)?.doubleValue
        about.ratingsCount = (stats["ratingsCount"] as? NSNumber)?.intValue
        if let counts = (stats["ratingsCountDist"] as? [NSNumber])?.map(\.intValue), counts.count == 5 {
            about.ratingsByStars = counts
        }
        about.reviewsCount = (stats["textReviewsCount"] as? NSNumber)?.intValue
        about.contributors = (book["secondaryContributorEdges"] as? [[String: Any]] ?? []).compactMap { edge in
            guard let name = contributorName(edge, in: apollo) else { return nil }
            return Contributor(name: name, role: text(edge["role"]) ?? "")
        }
        about.awards = (workDetails["awardsWon"] as? [[String: Any]] ?? []).compactMap { award in
            guard let name = text(award["name"]) else { return nil }
            let year = date(award["awardedAt"]).map { Calendar(identifier: .gregorian).component(.year, from: $0) }
            return Award(name: name, year: year, won: (award["designation"] as? String) == "WINNER")
        }
        about.characters = names(workDetails["characters"])
        about.places = names(workDetails["places"])
        return about
    }

    private static func contributorName(_ edge: [String: Any]?, in apollo: [String: Any]) -> String? {
        guard let ref = (edge?["node"] as? [String: Any])?["__ref"] as? String,
              let name = (apollo[ref] as? [String: Any])?["name"] as? String, !name.isEmpty else { return nil }
        return name
    }

    private static func authorName(fromJSONLD html: String) -> String? {
        guard let tagRange = html.range(of: #"<script type="application/ld\+json">"#, options: .regularExpression),
              let closeRange = html.range(of: "</script>", range: tagRange.upperBound..<html.endIndex),
              let data = html[tagRange.upperBound..<closeRange.lowerBound].data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authors = root["author"] as? [[String: Any]] else { return nil }
        return authors.first?["name"] as? String
    }

    /// The JSON-LD block (present for SEO) carries a plain author profile
    /// URL directly — simpler than resolving the apolloState's opaque
    /// `Contributor:kca://author/...` references.
    private static func authorURL(from html: String) -> URL? {
        guard let tagRange = html.range(of: #"<script type="application/ld\+json">"#, options: .regularExpression),
              let closeRange = html.range(of: "</script>", range: tagRange.upperBound..<html.endIndex),
              let data = html[tagRange.upperBound..<closeRange.lowerBound].data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authors = root["author"] as? [[String: Any]],
              let urlString = authors.first?["url"] as? String
        else { return nil }
        return URL(string: urlString)
    }

    // MARK: - __NEXT_DATA__

    private static func apolloState(from html: String) -> [String: Any]? {
        guard let tagRange = html.range(of: #"<script id="__NEXT_DATA__" type="application/json">"#),
              let closeRange = html.range(of: "</script>", range: tagRange.upperBound..<html.endIndex)
        else { return nil }

        let json = html[tagRange.upperBound..<closeRange.lowerBound]
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = root["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let apollo = pageProps["apolloState"] as? [String: Any]
        else { return nil }
        return apollo
    }

    /// The page's own book — the apolloState also holds other books
    /// (series, "readers also enjoyed"), told apart by `legacyId`.
    private static func bookEntity(bookID: String, in apollo: [String: Any]) -> [String: Any]? {
        for (_, value) in apollo {
            guard let entry = value as? [String: Any],
                  entry["__typename"] as? String == "Book",
                  let legacyId = entry["legacyId"],
                  String(describing: legacyId) == bookID
            else { continue }
            return entry
        }
        return nil
    }

    /// The book's main series — `bookSeries` lists it first — with its
    /// position, resolved through the Apollo reference to the series' title
    /// and page.
    private static func series(of book: [String: Any]?, in apollo: [String: Any]) -> GoodreadsSeries.Ref? {
        guard let first = (book?["bookSeries"] as? [[String: Any]])?.first,
              let ref = (first["series"] as? [String: Any])?["__ref"] as? String,
              let entry = apollo[ref] as? [String: Any],
              let title = entry["title"] as? String, !title.isEmpty,
              let url = (entry["webUrl"] as? String).flatMap(URL.init(string:)) else { return nil }
        let position = (first["userPosition"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return GoodreadsSeries.Ref(title: title, position: position, url: url)
    }

    /// Goodreads' genre list for the book, most-voted first.
    private static func workID(of book: [String: Any]?, in apollo: [String: Any]) -> String? {
        guard let ref = (book?["work"] as? [String: Any])?["__ref"] as? String,
              let work = apollo[ref] as? [String: Any], let legacy = work["legacyId"] else { return nil }
        return String(describing: legacy)
    }

    private static func genres(of book: [String: Any]?) -> [String] {
        let list = book?["bookGenres"] as? [[String: Any]] ?? []
        return list.compactMap { ($0["genre"] as? [String: Any])?["name"] as? String }
    }

    private static func reviews(from apollo: [String: Any]) -> [Review] {
        guard let rootQuery = apollo["ROOT_QUERY"] as? [String: Any] else { return [] }

        // getReviews' key sometimes carries serialized arguments — find it by prefix.
        guard let key = rootQuery.keys.first(where: { $0.hasPrefix("getReviews") }),
              let connection = rootQuery[key] as? [String: Any],
              let edges = connection["edges"] as? [[String: Any]]
        else { return [] }

        return edges.compactMap { edge -> Review? in
            guard let node = edge["node"] as? [String: Any],
                  let ref = node["__ref"] as? String,
                  let entry = apollo[ref] as? [String: Any]
            else { return nil }
            return review(from: entry, in: apollo)
        }
    }

    private static func review(from entry: [String: Any], in apollo: [String: Any]) -> Review? {
        guard let id = entry["id"] as? String else { return nil }

        var name = String(localized: "A reader")
        var avatar: URL?
        var profile: URL?
        var isAuthor: Bool?
        var followers: Int?
        if let creatorRef = (entry["creator"] as? [String: Any])?["__ref"] as? String,
           let user = apollo[creatorRef] as? [String: Any] {
            name = user["name"] as? String ?? name
            avatar = (user["imageUrlSquare"] as? String).flatMap(URL.init(string:))
            profile = (user["webUrl"] as? String).flatMap(URL.init(string:))
            isAuthor = user["isAuthor"] as? Bool
            followers = (user["followersCount"] as? NSNumber)?.intValue
        }

        let rating = entry["rating"] as? Int
        let html = entry["text"] as? String ?? ""
        let likeCount = entry["likeCount"] as? Int

        return Review(
            id: id,
            reviewerName: name,
            reviewerAvatarURL: avatar,
            rating: (rating ?? 0) > 0 ? rating : nil,
            text: plainText(fromHTML: html),
            likeCount: likeCount,
            reviewerURL: profile,
            reviewerIsAuthor: isAuthor,
            reviewerFollowers: followers
        )
    }

    /// Good-enough HTML stripping for a review preview — not a renderer.
    static func plainText(fromHTML html: String) -> String {
        var text = html
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
