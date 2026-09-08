import Foundation

/// Search talks to the same public JSON endpoint the CLI uses
/// (`/book/auto_complete?format=json`). No login needed.
enum SearchClient {

    static func search(_ query: String) async throws -> [Book] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://www.goodreads.com/book/auto_complete")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "q", value: trimmed)
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("GoodreadsGUI/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError("Goodreads returned HTTP \(http.statusCode).")
        }

        let results: [RawResult]
        do {
            results = try JSONDecoder().decode([RawResult].self, from: data)
        } catch {
            throw AppError("Couldn't read the search response. Goodreads may have changed the endpoint.")
        }

        return results.compactMap { raw in
            guard let id = raw.bookId?.string, !id.isEmpty else { return nil }
            let title = raw.bookTitleBare ?? raw.title ?? "Untitled"
            return Book(
                id: id,
                title: title,
                author: raw.author?.name ?? "Unknown author",
                coverURL: raw.imageUrl.flatMap(URL.init(string:)),
                rating: raw.avgRating?.string
            )
        }
    }
}

// MARK: - Wire format

private struct RawResult: Decodable {
    let bookId: Loose?
    let title: String?
    let bookTitleBare: String?
    let imageUrl: String?
    let avgRating: Loose?
    let author: Author?

    struct Author: Decodable {
        let name: String?
    }
}

/// Goodreads is inconsistent about whether these come back as strings or numbers.
private struct Loose: Decodable {
    let string: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            string = value
        } else if let value = try? container.decode(Int.self) {
            string = String(value)
        } else if let value = try? container.decode(Double.self) {
            string = String(format: "%.2f", value)
        } else {
            string = ""
        }
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
