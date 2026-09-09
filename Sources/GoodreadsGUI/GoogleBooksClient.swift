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

        var q = trimmed
        let subjectTerm = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if !subjectTerm.isEmpty { q += " subject:\"\(subjectTerm)\"" }

        return try await volumes(q: q, langRestrict: language.restrictCode, sortNewest: sortNewest)
    }

    /// Used by suggestions to find more books by an author already read.
    static func searchByAuthor(_ author: String) async throws -> [Book] {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await volumes(q: "inauthor:\"\(trimmed)\"")
    }

    private static func volumes(q: String,
                                langRestrict: String? = nil,
                                sortNewest: Bool = false,
                                maxResults: Int = 20) async throws -> [Book] {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "orderBy", value: sortNewest ? "newest" : "relevance")
        ]
        if let langRestrict {
            components.queryItems?.append(URLQueryItem(name: "langRestrict", value: langRestrict))
        }

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
                ?? "Google Books returned HTTP \(http.statusCode)."
            let hint = apiKey.isEmpty ? " Add a free API key in Settings — the shared tier is out of quota." : ""
            throw AppError(message + hint)
        }

        let decoded: VolumesResponse
        do {
            decoded = try JSONDecoder().decode(VolumesResponse.self, from: data)
        } catch {
            throw AppError("Couldn't read Google Books' response.")
        }

        return (decoded.items ?? []).compactMap(book(from:))
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
            author: (info.authors ?? []).joined(separator: ", ").ifEmpty("Unknown author"),
            coverURL: cover.flatMap(URL.init(string:)),
            rating: info.averageRating.map { String(format: "%.1f", $0) },
            publisher: info.publisher,
            isbn: isbn,
            language: info.language,
            description: info.description,
            pageCount: info.pageCount,
            publishedDate: info.publishedDate
        )
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
