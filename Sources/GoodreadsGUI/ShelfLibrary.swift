import Foundation

struct ShelfEntry: Identifiable, Hashable {
    let id: String          // review id when we have one, else book id
    let bookID: String
    let reviewID: String?
    let title: String
    let author: String
    let coverURL: URL?
    let progress: Int?      // percent, currently-reading only

    var asBook: Book {
        Book(id: bookID, title: title, author: author, coverURL: coverURL, rating: nil)
    }
}

/// Reads shelf contents from `/review/list`, the old Rails "My Books" page.
/// Its `print=true` view is a plain table — far more stable to parse than the
/// React shelf UI, and it's the same page the website itself still serves.
enum ShelfLibrary {

    /// Goodreads paginates at 100 per request; this fetches the first page only.
    static func load(_ shelf: Shelf) async throws -> [ShelfEntry] {
        let session = WebSession.shared

        var components = URLComponents(string: "https://www.goodreads.com/review/list")!
        components.queryItems = [
            URLQueryItem(name: "shelf", value: shelf.rawValue),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "print", value: "true"),
            URLQueryItem(name: "view", value: "table")
        ]

        try await session.load(components.url!)

        let landedURL = await session.currentURL?.absoluteString ?? ""
        if landedURL.contains("sign_in") {
            throw AppError("Signed out — log in to see your shelves.")
        }

        let raw = try await session.evaluate(extractScript)
        guard let data = raw.data(using: .utf8) else {
            throw AppError("Couldn't read the shelf page.")
        }

        let rows = try JSONDecoder().decode([Row].self, from: data)
        return rows.compactMap { row in
            guard !row.bookId.isEmpty else { return nil }
            return ShelfEntry(
                id: row.reviewId ?? row.bookId,
                bookID: row.bookId,
                reviewID: row.reviewId,
                title: row.title,
                author: row.author,
                coverURL: row.cover.flatMap(URL.init(string:)),
                progress: row.progress
            )
        }
    }

    private struct Row: Decodable {
        let bookId: String
        let reviewId: String?
        let title: String
        let author: String
        let cover: String?
        let progress: Int?
    }

    private static let extractScript = """
    const rows = [...document.querySelectorAll('tr.bookalike, tr[id^="review_"]')];

    const idFromHref = (href) => {
        if (!href) return '';
        const match = href.match(/\\/book\\/show\\/(\\d+)/);
        return match ? match[1] : '';
    };

    const text = (row, cls) => {
        const cell = row.querySelector('td.field.' + cls + ' .value');
        return cell ? cell.textContent.trim().replace(/\\s+/g, ' ') : '';
    };

    const out = rows.map(row => {
        const link = row.querySelector('td.field.title a, td.field.cover a');
        const bookId = idFromHref(link ? link.getAttribute('href') : '');

        const reviewMatch = (row.id || '').match(/review_(\\d+)/);
        const img = row.querySelector('td.field.cover img');

        // The list view shows author as "Last, First" — flip it back.
        let author = text(row, 'author');
        if (author.includes(',')) {
            const parts = author.split(',');
            author = (parts[1] || '').trim() + ' ' + parts[0].trim();
        }

        // Bigger cover than the 50px thumbnail the table uses.
        let cover = img ? img.getAttribute('src') : null;
        if (cover) cover = cover.replace(/\\._S[XY]\\d+_/, '._SY160_');

        return {
            bookId,
            reviewId: reviewMatch ? reviewMatch[1] : null,
            title: (text(row, 'title') || (link ? link.getAttribute('title') : '') || '').trim(),
            author: author.trim(),
            cover,
            progress: null
        };
    }).filter(r => r.bookId);

    return JSON.stringify(out);
    """
}
