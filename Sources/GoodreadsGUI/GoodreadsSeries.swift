import Foundation

/// A book series and its volumes, read from the public `/series/<id>` page.
///
/// That page is the older React-on-Rails kind: each list of books is a
/// `ReactComponents.SeriesList` element whose `data-react-props` attribute
/// holds the list as HTML-escaped JSON — `series` (the books) and
/// `seriesHeaders` (their labels, "Book 1", "Book 2.5", "Book 1-3"…, in the
/// same order).
enum GoodreadsSeries {

    /// What a book page says about the series it belongs to.
    struct Ref: Codable, Hashable, Sendable {
        let title: String
        /// As Goodreads writes it: "1", "2.5", sometimes "1-3".
        let position: String?
        let url: URL
    }

    struct Volume: Codable, Hashable, Sendable, Identifiable {
        let bookID: String
        let title: String
        let author: String
        let coverURL: URL?
        /// "Book 2", "Book 1-3", …
        let label: String
        /// The number in `label` when it's a single one ("Book 2.5" → 2.5);
        /// nil for ranges, parts and box sets.
        let position: Double?

        var id: String { bookID }

        var asBook: Book {
            Book(id: bookID, title: title, author: author, coverURL: coverURL, rating: nil,
                 goodreadsID: bookID)
        }
    }

    static func volumes(at url: URL) async throws -> [Volume] {
        let key = url.absoluteString
        if let hit = await DataCache.shared.read([Volume].self, "series", key, ttl: DataCache.TTL.series),
           !hit.isStale {
            return hit.value
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError("Goodreads returned HTTP \(http.statusCode).")
        }
        let volumes = parse(html: String(decoding: data, as: UTF8.self))
        if !volumes.isEmpty { await DataCache.shared.write(volumes, "series", key) }
        return volumes
    }

    /// Every volume on the page, in page order. No network — tests run it
    /// against a saved page.
    static func parse(html: String) -> [Volume] {
        let pattern = #"data-react-class="ReactComponents\.SeriesList" data-react-props="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)

        var volumes: [Volume] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: range) {
            guard let propsRange = Range(match.range(at: 1), in: html),
                  let data = unescapeHTML(String(html[propsRange])).data(using: .utf8),
                  let props = try? JSONDecoder().decode(ListProps.self, from: data) else { continue }

            for (index, item) in props.series.enumerated() {
                let book = item.book
                guard !book.bookId.isEmpty, seen.insert(book.bookId).inserted else { continue }
                let label = index < props.seriesHeaders.count ? props.seriesHeaders[index] : ""
                volumes.append(Volume(
                    bookID: book.bookId,
                    title: book.bookTitleBare ?? book.title,
                    author: book.author?.name ?? "",
                    coverURL: book.imageUrl.flatMap(URL.init(string:)),
                    label: label,
                    position: position(fromLabel: label)
                ))
            }
        }
        return volumes
    }

    /// The volume after `position`: the next whole-numbered book if there is
    /// one (so "Book 1" leads to "Book 2", not to a "Book 1.5" novella),
    /// otherwise the next numbered one of any kind.
    static func next(after position: String?, in volumes: [Volume]) -> Volume? {
        guard let current = position.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) else {
            return nil
        }
        let later = volumes.filter { ($0.position ?? -1) > current }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        return later.first { $0.position?.rounded() == $0.position } ?? later.first
    }

    /// "Book 2" → 2, "Book 4.5" → 4.5, "Book 1-3" / "Book 2 part 1/2" → nil.
    static func position(fromLabel label: String) -> Double? {
        let words = label.split(separator: " ")
        guard words.count == 2 else { return nil }
        return Double(words[1])
    }

    private static func unescapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Wire format

    private struct ListProps: Decodable {
        let series: [Item]
        let seriesHeaders: [String]
    }

    private struct Item: Decodable {
        let book: BookProps
    }

    private struct BookProps: Decodable {
        let bookId: String
        let title: String
        let bookTitleBare: String?
        let imageUrl: String?
        let author: Author?
    }

    private struct Author: Decodable {
        let name: String
    }
}
