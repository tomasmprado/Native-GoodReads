import Foundation

struct Suggestion: Identifiable, Hashable, Codable {
    let book: Book
    let reason: String
    var language: String?

    var id: String { book.id }
}

/// Builds recommendations from what you finished recently.
///
/// Goodreads has no recommendation API worth using, so this works from what we
/// can see: the authors you've been reading, and their other books you don't
/// already own.
enum Suggestions {

    static func build(from readEntries: [ShelfEntry],
                      excludingTitles shelvedTitles: Set<String>,
                      windowDays: Int,
                      language: BookLanguage,
                      includeUnknown: Bool) async throws -> (items: [Suggestion], basis: [ShelfEntry]) {

        let recent = recentlyRead(readEntries, withinDays: windowDays)
        guard !recent.isEmpty else { return ([], []) }

        // Most-read authors first — repetition is the strongest signal here.
        var tally: [String: Int] = [:]
        for entry in recent where !entry.author.isEmpty {
            tally[entry.author, default: 0] += 1
        }
        let authors = tally.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(6)
            .map(\.key)

        var candidates: [Suggestion] = []
        var seen = Set<String>()

        for author in authors {
            // Language comes back with the search result itself — Google
            // Books reports it cleanly, unlike Goodreads' inconsistent pages.
            guard let found = try? await GoogleBooksClient.searchByAuthor(author) else { continue }

            for book in found {
                guard !shelvedTitles.contains(normalizedTitle(book.title)),
                      seen.insert(book.id).inserted else { continue }
                guard looksLikeSameAuthor(book.author, author) else { continue }
                guard language.matches(book.language) || (book.language == nil && includeUnknown) else { continue }

                var suggestion = Suggestion(book: book, reason: String(localized: "More from \(author)"))
                suggestion.language = book.language
                candidates.append(suggestion)
                if candidates.count >= 40 { break }
            }
            if candidates.count >= 40 { break }
        }

        return (Array(candidates.prefix(15)), recent)
    }

    // MARK: - Recency

    static func recentlyRead(_ entries: [ShelfEntry], withinDays days: Int) -> [ShelfEntry] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        return entries.filter { entry in
            guard let text = entry.dateRead, let date = parseDate(text) else { return false }
            return date >= cutoff
        }
    }

    /// The table prints dates as "Aug 12, 2026", sometimes without the day.
    static func parseDate(_ text: String) -> Date? {
        let formats = ["MMM dd, yyyy", "MMM d, yyyy", "MMM yyyy", "yyyy-MM-dd"]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Two spellings of one author ("Agatha Christie" vs "Christie, Agatha")
    /// should match; two different people shouldn't. Requiring any shared
    /// token was too loose — "John Smith" and "John Doe" would match on
    /// "john" alone. The surname (the last token in "First Last" order, which
    /// is what both Goodreads' flipped author field and Google Books use) is
    /// the discriminating part, so require that specifically.
    ///
    /// Internal rather than private so tests can hit it directly — this is
    /// exactly the kind of string-matching heuristic that's cheap to get
    /// subtly wrong (the CHANGELOG already has one bug here) and cheap to
    /// pin down with a test.
    static func looksLikeSameAuthor(_ a: String, _ b: String) -> Bool {
        let tokens: (String) -> [String] = { name in
            name.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        }
        guard let leftSurname = tokens(a).last, let rightSurname = tokens(b).last else { return false }
        return leftSurname == rightSurname
    }

    /// For matching a candidate against your shelves — Goodreads shelf
    /// entries never carry an ISBN, only title/author, so exclusion has to
    /// work off title text rather than an id.
    static func normalizedTitle(_ title: String) -> String {
        title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Because you loved…

extension Suggestions {

    /// A friend's Read shelf, for "Because you loved…".
    struct FriendShelf: Sendable {
        let name: String
        let read: [ShelfEntry]
    }

    /// Books friends loved (5★), from friends who loved the same books you
    /// did — the more of your favourites they share, the higher their
    /// picks go. Nothing already on your shelves.
    static func lovedByFriends(mine: [ShelfEntry], friends: [FriendShelf],
                               shelvedIDs: Set<String>, shelvedTitles: Set<String>,
                               limit: Int = 15) -> [Suggestion] {
        var favourites = mine.filter { ($0.rating ?? 0) >= 5 }
        if favourites.count < 3 { favourites = mine.filter { ($0.rating ?? 0) >= 4 } }
        let favouriteIDs = Dictionary(favourites.map { ($0.bookID, $0) }, uniquingKeysWith: { a, _ in a })
        let favouriteTitles = Dictionary(favourites.map { (normalizedTitle($0.title), $0) }, uniquingKeysWith: { a, _ in a })

        struct Candidate { var entry: ShelfEntry; var score: Int; var friend: String; var because: String; var friends: Set<String> }
        var candidates: [String: Candidate] = [:]
        for friend in friends {
            let shared = friend.read.compactMap { entry -> ShelfEntry? in
                guard (entry.rating ?? 0) >= 4 else { return nil }
                return favouriteIDs[entry.bookID] ?? favouriteTitles[normalizedTitle(entry.title)]
            }
            guard let example = shared.first else { continue }
            for entry in friend.read where (entry.rating ?? 0) >= 5 {
                let title = normalizedTitle(entry.title)
                guard !shelvedIDs.contains(entry.bookID), !shelvedTitles.contains(title) else { continue }
                var candidate = candidates[title] ?? Candidate(entry: entry, score: 0, friend: friend.name,
                                                               because: example.title, friends: [])
                guard candidate.friends.insert(friend.name).inserted else { continue }
                candidate.score += shared.count
                candidates[title] = candidate
            }
        }
        return candidates.values
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry.title < $1.entry.title }
            .prefix(limit)
            .map { candidate in
                let others = candidate.friends.count - 1
                let reason = others > 0
                    ? String(localized: "Loved by \(candidate.friend) and \(others) more, who also loved \(candidate.because)")
                    : String(localized: "Loved by \(candidate.friend), who also loved \(candidate.because)")
                return Suggestion(book: candidate.entry.asBook, reason: reason)
            }
    }
}

extension LibraryModel {
    /// From friends' Read shelves as saved by "Friends who read this".
    func loadLovedSuggestions() async {
        if friendsBooks.isEmpty { friendsBooks = await FriendsBooks.index() }
        guard !friendsBooks.isEmpty, let mine = ShelfCache.read(.read)?.entries, !mine.isEmpty else { return }
        var friends: [Suggestions.FriendShelf] = []
        for library in friendsBooks.values {
            let userID = GoodreadsFriends.userID(from: library.profileURL) ?? library.friendID
            if let read = await DataCache.shared.read([ShelfEntry].self, "friend-shelf", "\(userID)/read", ttl: .infinity)?.value {
                friends.append(.init(name: library.name, read: read))
            }
        }
        var ids = Set<String>(), titles = Set<String>()
        for shelf in shelves {
            for entry in ShelfCache.read(shelf)?.entries ?? [] {
                ids.insert(entry.bookID)
                titles.insert(Suggestions.normalizedTitle(entry.title))
            }
        }
        lovedSuggestions = Suggestions.lovedByFriends(mine: mine, friends: friends, shelvedIDs: ids, shelvedTitles: titles)
    }
}
