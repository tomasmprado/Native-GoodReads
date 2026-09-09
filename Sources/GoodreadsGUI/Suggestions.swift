import Foundation

struct Suggestion: Identifiable, Hashable {
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

                var suggestion = Suggestion(book: book, reason: "More from \(author)")
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
    private static func looksLikeSameAuthor(_ a: String, _ b: String) -> Bool {
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
