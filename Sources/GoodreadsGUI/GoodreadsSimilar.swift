import Foundation

/// "Readers who enjoyed this also enjoyed": the public
/// `/book/similar/<work id>` page, which is plain server-rendered HTML —
/// each book a `schema.org/Book` block with its link, cover, author,
/// average rating, number of ratings and the start of its description.
enum GoodreadsSimilar {

    struct Item: Codable, Sendable, Equatable {
        let bookID: String
        let title: String
        let author: String
        let coverURL: URL?
        let rating: Double?
        let ratingsCount: Int?
        let blurb: String?
        /// The work all its editions share. Absent from lists saved before 3.1.
        var workID: String? = nil
        var pages: Int? = nil

        var asBook: Book {
            var book = Book(id: bookID, title: title, author: author, coverURL: coverURL,
                            rating: rating.map { String(format: "%.2f", $0) }, goodreadsID: bookID)
            book.description = blurb
            book.pageCount = pages
            return book
        }
    }

    /// The work id of a book, from its Goodreads page (saved, or fetched once).
    static func workID(for bookID: String) async -> String? {
        if let detail = await DataCache.shared.read(GoodreadsBookPage.Detail.self, "book-page", bookID, ttl: .infinity)?.value,
           let work = detail.workID {
            return work
        }
        guard let detail = try? await GoodreadsBookPage.fetch(bookID: bookID) else { return nil }
        await DataCache.shared.write(detail, "book-page", bookID)
        return detail.workID
    }

    /// Books readers of `bookID` also enjoyed, the book itself left out.
    /// Saved for two weeks.
    static func similar(to bookID: String) async -> [Item] {
        if let hit = await DataCache.shared.read([Item].self, "similar-books", bookID, ttl: 14 * 24 * 3600), !hit.isStale {
            return hit.value
        }
        guard let work = await workID(for: bookID),
              let url = URL(string: "https://www.goodreads.com/book/similar/\(work)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        // The list starts with the book itself, often another edition of it.
        let found = parse(html: String(decoding: data, as: UTF8.self)).filter { $0.bookID != bookID && $0.workID != work }
        if !found.isEmpty { await DataCache.shared.write(found, "similar-books", bookID) }
        return found
    }

    /// Each book on the page is a `ReactComponents.SimilarBooksList` whose
    /// props hold it as JSON; the `schema.org/Book` markup is the fallback.
    static func parse(html: String) -> [Item] {
        let fromProps = parseProps(html)
        return fromProps.isEmpty ? parseMarkup(html) : fromProps
    }

    private static func parseProps(_ html: String) -> [Item] {
        let pattern = #"data-react-class="ReactComponents\.SimilarBooksList" data-react-props="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var items: [Item] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html),
                  let data = unescape(String(html[range])).data(using: .utf8),
                  let props = try? JSONDecoder().decode(Props.self, from: data) else { continue }
            for entry in props.similarBooks {
                let book = entry.book
                guard seen.insert(book.bookId).inserted else { continue }
                let text = (book.description?.html ?? book.description?.truncatedHtml).map { html in
                    unescape(html.replacingOccurrences(of: "<br />", with: "\n").replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
                }
                items.append(Item(bookID: book.bookId, title: book.title, author: book.author?.name ?? "",
                                  coverURL: book.imageUrl.flatMap { URL(string: biggerCover($0)) },
                                  rating: book.avgRating, ratingsCount: book.ratingsCount, blurb: text,
                                  workID: book.workId, pages: book.numPages))
            }
        }
        return items
    }

    private static func biggerCover(_ url: String) -> String {
        url.replacingOccurrences(of: #"\._S[XY]\d+_\."#, with: ".", options: .regularExpression)
    }

    private struct Props: Decodable {
        struct Entry: Decodable { let book: Props.Book }
        struct Book: Decodable {
            struct Author: Decodable { let name: String }
            struct Description: Decodable { let html: String?; let truncatedHtml: String? }
            let bookId: String
            let workId: String?
            let title: String
            let imageUrl: String?
            let numPages: Int?
            let avgRating: Double?
            let ratingsCount: Int?
            let author: Author?
            let description: Description?
        }
        let similarBooks: [Entry]
    }

    private static func parseMarkup(_ html: String) -> [Item] {
        let blocks = html.components(separatedBy: #"itemtype="http://schema.org/Book""#).dropFirst()
        return blocks.compactMap { block -> Item? in
            guard let id = first(#"href="/book/show/(\d+)"#, in: block),
                  let title = first(#"itemprop="name"[^>]*>([^<]+)</span>"#, in: block) else { return nil }
            let author = first(#"itemprop="author".*?itemprop="url"[^>]*>([^<]+)</a>"#, in: block) ?? ""
            let cover = first(#"<img src="([^"]+)""#, in: block).map(biggerCover)
            let rating = first(#"aria-label="Rated ([\d.]+) of 5""#, in: block).flatMap(Double.init)
            let count = first(#">([\d,]+)</span><span[^>]*> Ratings"#, in: block)
                .flatMap { Int($0.replacingOccurrences(of: ",", with: "")) }
            let blurb = first(#"class="expandableHtml"[^>]*>\s*<span[^>]*>(.*?)</span>"#, in: block)
            return Item(bookID: id, title: unescape(title), author: unescape(author),
                        coverURL: cover.flatMap(URL.init(string:)), rating: rating, ratingsCount: count,
                        blurb: blurb.map(unescape).map { $0.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression) })
        }
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unescape(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result
    }
}
