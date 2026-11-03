import Foundation

/// Everything else on a Goodreads profile page, beyond the name, stats and
/// updates `GoodreadsFriends.Profile` always had: details, the reading
/// challenge, favourite books and genres, shelves, what they're reading,
/// quotes, friends and who they follow. Each part is optional — what a page
/// shows depends on the member's privacy settings and whether they're a friend.
struct ProfileDetails: Codable, Equatable, Sendable {
    struct Row: Codable, Equatable, Sendable, Hashable {
        let title: String
        let value: String
    }

    struct BookLink: Codable, Equatable, Sendable, Hashable, Identifiable {
        let bookID: String
        let title: String
        let author: String?
        let coverURL: URL?
        var id: String { bookID }
    }

    struct ShelfLink: Codable, Equatable, Sendable, Hashable, Identifiable {
        let name: String
        let count: Int?
        var id: String { name }
    }

    struct Person: Codable, Equatable, Sendable, Hashable, Identifiable {
        let name: String
        let url: URL
        let avatarURL: URL?
        var isAuthor: Bool { url.path.contains("/author/show/") }
        var id: String { url.absoluteString }
    }

    struct Quote: Codable, Equatable, Sendable, Hashable, Identifiable {
        let text: String
        let attribution: String?
        var id: String { text }
    }

    struct Challenge: Codable, Equatable, Sendable {
        let year: Int?
        let read: Int
        let goal: Int
    }

    var rows: [Row] = []
    var challenge: Challenge?
    var favouriteBooks: [BookLink] = []
    var currentlyReading: [BookLink] = []
    var shelves: [ShelfLink] = []
    var quotes: [Quote] = []
    var favouriteGenres: [String] = []
    var friends: [Person] = []
    var friendCount: Int?
    var following: [Person] = []
    var yearInBooksURL: URL?
    /// The page says the rest is only for friends or signed-in members.
    var isRestricted = false

    var isEmpty: Bool {
        rows.isEmpty && challenge == nil && favouriteBooks.isEmpty && currentlyReading.isEmpty
            && shelves.isEmpty && quotes.isEmpty && favouriteGenres.isEmpty && friends.isEmpty
    }

    /// "Maria Mira has read 61 books of their goal of 52!" or "12 of 40 books read".
    static func parseChallenge(_ text: String, year: Int?) -> Challenge? {
        let patterns = [
            #"read\s+([\d,.]+)\s+books?\s+of\s+(?:their|his|her|your)\s+goal\s+of\s+([\d,.]+)"#,
            #"([\d,.]+)\s+of\s+([\d,.]+)\s+books"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text),
                  let read = Int(text[a].filter(\.isNumber)), let goal = Int(text[b].filter(\.isNumber)), goal > 0
            else { continue }
            return Challenge(year: year, read: read, goal: goal)
        }
        return nil
    }

    // MARK: Reading the page

    static func decode(_ raw: String) -> ProfileDetails? {
        guard let data = raw.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data), wire.ok else { return nil }
        func url(_ string: String?) -> URL? {
            guard let string, !string.isEmpty else { return nil }
            return URL(string: string, relativeTo: URL(string: "https://www.goodreads.com"))?.absoluteURL
        }
        // Thumbnails ask for a size ("…/10365._SY75_.jpg"); without it the full image comes back.
        func image(_ string: String?) -> URL? {
            url(string?.replacingOccurrences(of: #"\._[A-Z]{2}\d+_(?=\.)"#, with: "", options: .regularExpression))
        }
        func book(_ link: Wire.Book) -> BookLink? {
            guard let id = GoodreadsLookup.bookID(fromURL: link.url ?? "") else { return nil }
            var title = link.title ?? ""
            var author = link.author
            // Cover alt text is "Title by Author".
            if author == nil, let by = title.range(of: " by ", options: .backwards) {
                author = String(title[by.upperBound...])
                title = String(title[..<by.lowerBound])
            }
            guard !title.isEmpty else { return nil }
            return BookLink(bookID: id, title: title, author: author, coverURL: image(link.cover))
        }
        func person(_ link: Wire.Person) -> Person? {
            guard let name = link.name, !name.isEmpty, let target = url(link.url) else { return nil }
            return Person(name: name, url: target, avatarURL: url(link.avatar))
        }

        var details = ProfileDetails()
        details.rows = (wire.rows ?? []).compactMap { row in
            guard let title = row.title, let value = row.value, !title.isEmpty, !value.isEmpty else { return nil }
            return Row(title: title, value: value)
        }
        if let text = wire.challenge {
            details.challenge = parseChallenge(text, year: wire.challengeYear)
        }
        details.favouriteBooks = (wire.favourites ?? []).compactMap(book)
        details.currentlyReading = (wire.reading ?? []).compactMap(book)
        details.shelves = (wire.shelves ?? []).compactMap { text in
            // "to-read‎ (50)" — with an invisible direction mark.
            let clean = text.replacingOccurrences(of: "\u{200E}", with: "").trimmingCharacters(in: .whitespaces)
            guard let open = clean.lastIndex(of: "("), clean.hasSuffix(")") else {
                return clean.isEmpty ? nil : ShelfLink(name: clean, count: nil)
            }
            let name = clean[..<open].trimmingCharacters(in: .whitespaces)
            let count = Int(clean[clean.index(after: open)..<clean.index(before: clean.endIndex)].filter(\.isNumber))
            return name.isEmpty ? nil : ShelfLink(name: name, count: count)
        }
        details.quotes = (wire.quotes ?? []).compactMap { quote in
            guard let text = quote.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return Quote(text: text, attribution: quote.by?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        details.favouriteGenres = wire.genres ?? []
        details.friends = (wire.friends ?? []).compactMap(person)
        details.friendCount = wire.friendCount
        details.following = (wire.following ?? []).compactMap(person)
        details.yearInBooksURL = url(wire.yearInBooks)
        details.isRestricted = wire.restricted ?? false
        return details
    }

    private struct Wire: Decodable {
        struct Row: Decodable { let title: String?; let value: String? }
        struct Book: Decodable { let url: String?; let title: String?; let author: String?; let cover: String? }
        struct Person: Decodable { let name: String?; let url: String?; let avatar: String? }
        struct Quote: Decodable { let text: String?; let by: String? }
        let ok: Bool
        let rows: [Row]?
        let challenge: String?
        let challengeYear: Int?
        let favourites: [Book]?
        let reading: [Book]?
        let shelves: [String]?
        let quotes: [Quote]?
        let genres: [String]?
        let friends: [Person]?
        let friendCount: Int?
        let following: [Person]?
        let yearInBooks: String?
        let restricted: Bool?
    }

    /// Runs in the loaded profile page. Sections are found by their header
    /// text, which is how the page itself is laid out.
    static let script = """
    try {
        const clean = (s) => (s || '').replace(/\\s+/g, ' ').trim();
        const abs = (href) => { try { return href ? new URL(href, location.href).href : null; } catch (e) { return null; } };
        const boxes = Array.from(document.querySelectorAll('.bigBox'));
        const box = (re) => boxes.find(b => { const h = b.querySelector('h2'); return h && re.test(clean(h.textContent)); });
        const imgSrc = (img) => img ? (img.getAttribute('src') || img.getAttribute('data-src')) : null;

        const rows = Array.from(document.querySelectorAll('.userInfoBox .infoBoxRowTitle')).map(t => {
            const item = t.nextElementSibling;
            return { title: clean(t.textContent), value: item ? clean(item.innerText || item.textContent).replace(/\\s*\\.\\.\\.more$/, '') : null };
        });

        let challenge = null, challengeYear = null;
        const progress = document.querySelector('.profileChallenges .challengeProgress, .yearChallengeModule');
        if (progress) {
            challenge = clean(progress.textContent);
            const header = progress.closest('.bigBox') && progress.closest('.bigBox').querySelector('h2');
            const year = header && clean(header.textContent).match(/(\\d{4})/);
            if (year) challengeYear = Number(year[1]);
        }

        const favBox = box(/favorite books/i);
        const favourites = favBox ? Array.from(favBox.querySelectorAll('.imgGrid a')).map(a => {
            const img = a.querySelector('img');
            return { url: abs(a.getAttribute('href')), title: img ? img.getAttribute('alt') : clean(a.textContent), cover: abs(imgSrc(img)) };
        }) : [];

        const reading = Array.from(document.querySelectorAll('#currentlyReadingReviews .Updates')).map(u => {
            const bookA = u.querySelector('a.bookTitle') || Array.from(u.querySelectorAll('a[href*="/book/show/"]')).find(a => clean(a.textContent));
            const authorA = u.querySelector('a.authorName') || u.querySelector('a[href*="/author/show/"]');
            const img = u.querySelector('.firstcol img');
            return { url: bookA ? abs(bookA.getAttribute('href')) : null, title: bookA ? clean(bookA.textContent) : (img ? img.getAttribute('alt') : null),
                     author: authorA ? clean(authorA.textContent) : null, cover: abs(imgSrc(img)) };
        });

        const shelves = Array.from(document.querySelectorAll('.userShowPageShelfListItem')).map(a => clean(a.textContent));

        const quoteBox = box(/quotes/i);
        const quotes = quoteBox ? Array.from(quoteBox.querySelectorAll('.quoteText')).map(q => {
            const full = clean(q.textContent);
            const dash = full.lastIndexOf('―');
            return dash > 0 ? { text: full.slice(0, dash).trim(), by: full.slice(dash + 1).trim().replace(/,$/, '') } : { text: full, by: null };
        }) : [];

        const genreBox = box(/favorite genres/i);
        const genres = genreBox ? Array.from(genreBox.querySelectorAll('.bigBoxContent a')).map(a => clean(a.textContent)).filter(Boolean) : [];

        const people = (b) => b ? Array.from(b.querySelectorAll('a[href*="/user/show/"], a[href*="/author/show/"]')).map(a => {
            const img = a.querySelector('img');
            const candidates = [img && img.getAttribute('title'), a.getAttribute('title'), img && img.getAttribute('alt'), clean(a.textContent)]
                .map(clean).filter(n => n && !/\\.\\.\\.$/.test(n));
            const name = candidates[0] || clean(img ? img.getAttribute('alt') : a.textContent);
            return { name: clean(name), url: abs(a.getAttribute('href')), avatar: abs(imgSrc(img)) };
        }).filter(p => p.name) : [];
        const dedupe = (list) => { const seen = {}; return list.filter(p => { if (seen[p.url]) return false; seen[p.url] = 1; return true; }).filter(p => p.avatar || p.name); };
        const friendsBox = box(/friends\\s*\\(/i);
        let friendCount = null;
        if (friendsBox) { const m = clean(friendsBox.querySelector('h2').textContent).match(/\\(([\\d,]+)\\)/); if (m) friendCount = Number(m[1].replace(/,/g, '')); }
        const friends = dedupe(people(friendsBox)).filter(p => p.avatar);
        const following = dedupe(people(box(/is following/i))).filter(p => p.avatar);

        const yib = document.querySelector('.yyibLinkLink a');
        const restricted = /sign in to goodreads to learn more|only (friends|visible)/i.test(clean((document.querySelector('.userInfoBox') || {}).textContent || ''));

        return JSON.stringify({ ok: true, rows, challenge, challengeYear, favourites, reading, shelves, quotes, genres,
                                friends, friendCount, following, yearInBooks: yib ? abs(yib.getAttribute('href')) : null, restricted });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) });
    }
    """
}
