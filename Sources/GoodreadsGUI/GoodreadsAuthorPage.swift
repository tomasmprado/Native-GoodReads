import Foundation

/// An author's Goodreads page — bio, stats, and their books. Legacy
/// server-rendered HTML with no embedded JSON to lean on (unlike book pages'
/// `__NEXT_DATA__`), so this needs real DOM traversal and goes through the
/// shared `WKWebView`, the same as `GoodreadsFriends`.
enum GoodreadsAuthorPage {

    struct Detail: Codable {
        let name: String
        let photoURL: URL?
        let born: String?
        let website: URL?
        let genres: String?
        let bio: String?
        let averageRating: String?
        let ratingsCount: String?
        let books: [Book]
        // Absent from author pages cached before 2.8.
        var version: Int? = nil
        var birthplace: String? = nil
        var died: String? = nil
        var influences: String? = nil
        var reviewsCount: String? = nil
        var distinctWorks: String? = nil
        var followers: Int? = nil
        var series: [SeriesLink]? = nil
        var quotes: [String]? = nil

        static let currentVersion = 2
    }

    struct SeriesLink: Identifiable, Hashable, Codable {
        let title: String
        let url: URL
        var id: String { url.absoluteString }
    }

    struct Book: Identifiable, Hashable, Codable {
        let id: String              // Goodreads book id
        let title: String
        let coverURL: URL?
        let ratingLine: String?     // "3.98 avg rating — 771,179 ratings", shown as-is
    }

    @MainActor static func fetch(url: URL) async throws -> Detail {
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
            name: result.name ?? String(localized: "Author"),
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
            },
            version: Detail.currentVersion,
            birthplace: result.birthplace,
            died: result.died,
            influences: result.influences,
            reviewsCount: result.reviews,
            distinctWorks: result.works,
            followers: result.followers,
            series: (result.series ?? []).compactMap { link in
                guard let title = link.title, !title.isEmpty,
                      let url = link.url.flatMap({ URL(string: $0, relativeTo: URL(string: "https://www.goodreads.com"))?.absoluteURL })
                else { return nil }
                return SeriesLink(title: title, url: url)
            },
            quotes: result.quotes
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
        let birthplace: String?
        let died: String?
        let influences: String?
        let reviews: String?
        let works: String?
        let followers: Int?
        let series: [SeriesRow]?
        let quotes: [String]?
    }

    private struct SeriesRow: Decodable {
        let title: String?
        let url: String?
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

        const clean = (s) => (s || '').replace(/\\s+/g, ' ').trim();
        // Long values show a short version and keep the full one in a hidden span.
        const fullText = (el) => {
            if (!el) return null;
            const hidden = el.querySelector('span[id^="freeText"]:not([id^="freeTextContainer"])');
            return clean((hidden || el).textContent).replace(/\\s*\\.\\.\\.more$/, '') || null;
        };
        let birthplace = null;
        const bornTitle = [...document.querySelectorAll('.dataTitle')].find(t => clean(t.textContent) === 'Born');
        if (bornTitle && bornTitle.nextSibling && bornTitle.nextSibling.nodeType === 3) {
            birthplace = clean(bornTitle.nextSibling.textContent).replace(/^in\\s+/i, '') || null;
        }
        const aggregate = clean((document.querySelector('.hreview-aggregate') || {}).textContent || '');
        const reviews = (aggregate.match(/([\\d,]+)\\s+reviews/i) || [])[1] || null;
        const works = (aggregate.match(/([\\d,]+)\\s+distinct works/i) || [])[1] || null;
        let followers = null;
        for (const h of document.querySelectorAll('h2')) {
            const m = clean(h.textContent).match(/followers\\s*\\(([\\d,]+)\\)/i);
            if (m) { followers = Number(m[1].replace(/,/g, '')); break; }
        }
        const seriesBox = [...document.querySelectorAll('.bigBox')].find(b => /series by/i.test(clean((b.querySelector('h2') || {}).textContent)));
        const seen = {};
        const series = seriesBox ? [...seriesBox.querySelectorAll('a[href*="/series/"]')]
            .filter(a => !/\\/series\\/list/.test(a.getAttribute('href')) && clean(a.textContent))
            .filter(a => { const h = a.getAttribute('href'); if (seen[h]) return false; seen[h] = 1; return true; })
            .map(a => ({ title: clean(a.textContent), url: a.getAttribute('href') })).slice(0, 12) : [];
        const quotes = [...document.querySelectorAll('.quoteText')].slice(0, 5)
            .map(q => (q.innerText || q.textContent || '').replace(/[ \\t]+/g, ' ').replace(/\\s*―[^―]*$/, '').trim()).filter(Boolean);

        return JSON.stringify({
            ok: true,
            birthplace: birthplace,
            died: dataItemFor('Died') ? clean(dataItemFor('Died').textContent) : null,
            influences: fullText(dataItemFor('Influences')),
            reviews: reviews,
            works: works,
            followers: followers,
            series: series,
            quotes: quotes,
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
