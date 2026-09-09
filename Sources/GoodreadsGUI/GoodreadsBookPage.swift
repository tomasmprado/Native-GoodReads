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

    struct Detail {
        let language: String?
        let authorURL: URL?
        let reviews: [Review]
    }

    struct Review: Identifiable {
        let id: String
        let reviewerName: String
        let reviewerAvatarURL: URL?
        let rating: Int?
        let text: String
        let likeCount: Int?
    }

    static func fetch(bookID: String) async throws -> Detail {
        var request = URLRequest(url: URL(string: "https://www.goodreads.com/book/show/\(bookID)")!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError("Goodreads returned HTTP \(http.statusCode).")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw AppError("Couldn't read the book page.")
        }

        guard let apollo = apolloState(from: html) else {
            throw AppError("Couldn't find this book's data on the page.")
        }

        return Detail(
            language: language(bookID: bookID, in: apollo),
            authorURL: authorURL(from: html),
            reviews: reviews(from: apollo)
        )
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

    private static func language(bookID: String, in apollo: [String: Any]) -> String? {
        for (_, value) in apollo {
            guard let entry = value as? [String: Any],
                  entry["__typename"] as? String == "Book",
                  let legacyId = entry["legacyId"],
                  String(describing: legacyId) == bookID
            else { continue }

            let details = entry["details"] as? [String: Any]
            let language = details?["language"] as? [String: Any]
            return (language?["name"] as? String)?.lowercased()
        }
        return nil
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

        var name = "A reader"
        var avatar: URL?
        if let creatorRef = (entry["creator"] as? [String: Any])?["__ref"] as? String,
           let user = apollo[creatorRef] as? [String: Any] {
            name = user["name"] as? String ?? name
            avatar = (user["imageUrlSquare"] as? String).flatMap(URL.init(string:))
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
            likeCount: likeCount
        )
    }

    /// Good-enough HTML stripping for a review preview — not a renderer.
    private static func plainText(fromHTML html: String) -> String {
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
