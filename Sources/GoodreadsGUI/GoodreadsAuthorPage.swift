import Foundation

/// An author's Goodreads page — bio, stats, and their books. Legacy
/// server-rendered HTML with no embedded JSON to lean on (unlike book pages'
/// `__NEXT_DATA__`), so this needs real DOM traversal and goes through the
/// shared `WKWebView`, the same as `GoodreadsFriends`.
enum GoodreadsAuthorPage {

    struct Detail {
        let name: String
        let photoURL: URL?
        let born: String?
        let website: URL?
        let genres: String?
        let bio: String?
        let averageRating: String?
        let ratingsCount: String?
        let books: [Book]
    }

    struct Book: Identifiable, Hashable {
        let id: String              // Goodreads book id
        let title: String
        let coverURL: URL?
        let ratingLine: String?     // "3.98 avg rating — 771,179 ratings", shown as-is
    }

    static func fetch(url: URL) async throws -> Detail {
        let session = WebSession.shared

        // Reads the live document, so the load and the evaluate that depends
        // on it share one lock — otherwise another task's navigation could
        // land the page on something else in between.
        let raw = try await session.exclusive { () -> String in
            try await session.load(url)
            return try await session.evaluate(script, label: "author page")
        }
        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(Result.self, from: data),
              result.ok else {
            throw AppError("Couldn't read this author's page.")
        }

        return Detail(
            name: result.name ?? "Author",
            photoURL: result.photo.flatMap(URL.init(string:)),
            born: result.born,
            website: result.website.flatMap(URL.init(string:)),
            genres: result.genres,
            bio: result.bio,
            averageRating: result.averageRating,
            ratingsCount: result.ratingsCount,
            books: (result.books ?? []).compactMap { row in
                guard !row.id.isEmpty, !row.title.isEmpty else { return nil }
                return Book(id: row.id, title: row.title,
                           coverURL: row.cover.flatMap(URL.init(string:)), ratingLine: row.ratingLine)
            }
        )
    }

    private struct Result: Decodable {
        let ok: Bool
        let name: String?
        let photo: String?
        let born: String?
        let website: String?
        let genres: String?
        let bio: String?
        let averageRating: String?
        let ratingsCount: String?
        let books: [BookRow]?
    }

    private struct BookRow: Decodable {
        let id: String
        let title: String
        let cover: String?
        let ratingLine: String?
    }

    private static let script = """
    try {
        // Walks forward from a ".dataTitle" matching `label` to the next
        // ".dataItem" sibling — there can be plain text between them (e.g.
        // "Born" has a bare birthplace text node before the date's own div).
        function dataItemFor(label) {
            const titles = [...document.querySelectorAll('.dataTitle')];
            const title = titles.find(t => (t.textContent || '').trim() === label);
            if (!title) return null;
            let node = title.nextElementSibling;
            while (node && !node.classList.contains('dataItem')) node = node.nextElementSibling;
            return node;
        }

        const nameEl = document.querySelector('h1.authorName span[itemprop="name"], h1.authorName');
        const photoImg = document.querySelector('.authorLeftContainer img[itemprop="image"]');

        const bornEl = dataItemFor('Born');
        const websiteEl = dataItemFor('Website');
        const genreEl = dataItemFor('Genre');

        const bioEl = document.querySelector('[id^="freeTextauthor"]');

        const avgEl = document.querySelector('.hreview-aggregate .average');
        const countEl = document.querySelector('.hreview-aggregate .votes .value-title');

        const books = [];
        for (const row of document.querySelectorAll('table.tableList tr[itemtype="http://schema.org/Book"]')) {
            const link = row.querySelector('.bookTitle');
            if (!link) continue;
            const href = link.getAttribute('href') || '';
            const match = href.match(/\\/book\\/show\\/(\\d+)/);
            if (!match) continue;

            const cover = row.querySelector('img.bookCover');
            const mini = row.querySelector('.minirating');

            books.push({
                id: match[1],
                title: (link.textContent || '').trim(),
                cover: cover ? cover.getAttribute('src') : null,
                ratingLine: mini ? (mini.textContent || '').replace(/\\s+/g, ' ').trim() : null
            });
            if (books.length >= 30) break;
        }

        return JSON.stringify({
            ok: true,
            name: nameEl ? (nameEl.textContent || '').trim() : null,
            photo: photoImg ? photoImg.getAttribute('src') : null,
            born: bornEl ? (bornEl.textContent || '').trim() : null,
            website: websiteEl ? (websiteEl.querySelector('a') || {}).href : null,
            genres: genreEl ? (genreEl.textContent || '').replace(/\\s+/g, ' ').trim() : null,
            bio: bioEl ? (bioEl.textContent || '').trim() : null,
            averageRating: avgEl ? (avgEl.textContent || '').trim() : null,
            ratingsCount: countEl ? (countEl.textContent || '').replace(/\\s+/g, ' ').trim() : null,
            books: books
        });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) });
    }
    """
}
