import Foundation
import UserNotifications

/// Books just out (or about to be) by authors you keep coming back to —
/// anyone with two or more books on your Read shelf.
enum NewReleases {

    /// Your most-read authors, most books first.
    static func authors(from read: [ShelfEntry], limit: Int = 8) -> [String] {
        var tally: [String: Int] = [:]
        for entry in read where !entry.author.isEmpty { tally[entry.author, default: 0] += 1 }
        return tally.filter { $0.value >= 2 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    /// Published within the last year, or due within the next one. Google
    /// Books gives "2026", "2026-03" or "2026-03-04"; a bare year counts when
    /// it's this year or next.
    static func isRecent(_ published: String?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let published, !published.isEmpty else { return false }
        let parts = published.split(separator: "-").compactMap { Int($0) }
        guard let year = parts.first else { return false }
        let thisYear = calendar.component(.year, from: now)
        guard parts.count >= 2 else { return year == thisYear || year == thisYear + 1 }

        let date = calendar.date(from: DateComponents(year: year, month: parts[1],
                                                      day: parts.count >= 3 ? parts[2] : 1)) ?? .distantPast
        return abs(date.timeIntervalSince(now)) <= 365 * 86400
    }

    static func find(read: [ShelfEntry],
                     shelvedTitles: Set<String>,
                     language: BookLanguage,
                     includeUnknown: Bool) async -> [Suggestion] {
        var found: [Suggestion] = []
        var seen = Set<String>()
        for author in authors(from: read) {
            guard let books = try? await GoogleBooksClient.newestByAuthor(author) else { continue }
            for book in books {
                guard isRecent(book.publishedDate),
                      Suggestions.looksLikeSameAuthor(book.author, author),
                      !shelvedTitles.contains(Suggestions.normalizedTitle(book.title)),
                      seen.insert(Suggestions.normalizedTitle(book.title)).inserted,
                      language.matches(book.language) || (book.language == nil && includeUnknown)
                else { continue }
                var suggestion = Suggestion(book: book, reason: String(localized: "New from \(author)"))
                suggestion.language = book.language
                found.append(suggestion)
            }
        }
        return found.sorted { ($0.book.publishedDate ?? "") > ($1.book.publishedDate ?? "") }
    }

    // MARK: - Notifications

    private static let seenKey = "notifiedNewReleases"

    /// Posts one notification per book not announced before. The first run
    /// only remembers what's there, so turning this on is quiet.
    static func notify(about releases: [Suggestion]) async {
        let defaults = UserDefaults.standard
        let firstRun = defaults.object(forKey: seenKey) == nil
        var seen = Set(defaults.stringArray(forKey: seenKey) ?? [])
        let fresh = releases.filter { !seen.contains($0.book.id) }
        seen.formUnion(fresh.map(\.book.id))
        defaults.set(Array(seen), forKey: seenKey)
        guard !firstRun else { return }

        for release in fresh.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "New from \(release.book.author)")
            content.body = [release.book.title, release.book.publishedDate].compactMap { $0 }.joined(separator: " · ")
            content.sound = .default
            let request = UNNotificationRequest(identifier: "new-release-\(release.book.id)",
                                                content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
