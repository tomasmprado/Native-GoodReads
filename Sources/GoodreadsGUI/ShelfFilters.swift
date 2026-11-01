import Foundation

/// The shelf pane's Filter menu: by your rating, the year you read it, and
/// genre (genres known from book pages, see `BookExtras`).
struct ShelfFilters: Equatable {

    enum Rating: String, CaseIterable, Identifiable {
        case any, five, fourUp, threeUp, unrated
        var id: String { rawValue }

        var title: String {
            switch self {
            case .any:     return String(localized: "Any rating")
            case .five:    return "★★★★★"
            case .fourUp:  return String(localized: "★★★★ and up")
            case .threeUp: return String(localized: "★★★ and up")
            case .unrated: return String(localized: "Unrated")
            }
        }

        func matches(_ stars: Int?) -> Bool {
            let stars = stars ?? 0
            switch self {
            case .any:     return true
            case .five:    return stars == 5
            case .fourUp:  return stars >= 4
            case .threeUp: return stars >= 3
            case .unrated: return stars == 0
            }
        }
    }

    var rating: Rating = .any
    var year: Int?
    var genre: String?

    var isActive: Bool { rating != .any || year != nil || genre != nil }

    func matches(_ entry: ShelfEntry, extras: [String: BookExtras],
                 calendar: Calendar = .current) -> Bool {
        guard rating.matches(entry.rating) else { return false }
        if let year {
            guard let date = Suggestions.parseDate(entry.dateRead ?? ""),
                  calendar.component(.year, from: date) == year else { return false }
        }
        if let genre {
            guard extras[entry.bookID]?.genres.contains(genre) == true else { return false }
        }
        return true
    }

    /// Years something on this shelf was read, newest first.
    static func years(in entries: [ShelfEntry], calendar: Calendar = .current) -> [Int] {
        let years = entries.compactMap { Suggestions.parseDate($0.dateRead ?? "") }
            .map { calendar.component(.year, from: $0) }
        return Array(Set(years)).sorted(by: >)
    }

    /// The most common genres on this shelf, for the menu.
    static func genres(in entries: [ShelfEntry], extras: [String: BookExtras], limit: Int = 15) -> [String] {
        var tally: [String: Int] = [:]
        for entry in entries {
            for genre in (extras[entry.bookID]?.genres ?? []).prefix(5)
            where !ReadingStats.ignoredGenres.contains(genre) {
                tally[genre, default: 0] += 1
            }
        }
        return tally.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }
}

/// Your own order for Want to Read — what to read next first. Kept on this
/// Mac; Goodreads has no such order.
enum QueueOrder {

    private static let key = "toReadOrder"

    static var saved: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ bookIDs: [String]) {
        UserDefaults.standard.set(bookIDs, forKey: key)
    }

    /// `entries` in the saved order; books not placed yet keep the shelf's
    /// own order, after the placed ones.
    static func apply(_ entries: [ShelfEntry], order: [String] = saved) -> [ShelfEntry] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.enumerated().sorted { a, b in
            switch (rank[a.element.bookID], rank[b.element.bookID]) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The new full order after dragging rows in the visible list. Books
    /// the list didn't show (filtered out) keep their place at the end.
    static func moved(_ visible: [ShelfEntry], from source: IndexSet, to destination: Int,
                      previous order: [String] = saved) -> [String] {
        var ids = visible.map(\.bookID)
        let moving = source.map { ids[$0] }
        let insertAt = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { ids.remove(at: index) }
        ids.insert(contentsOf: moving, at: insertAt)
        let shown = Set(ids)
        return ids + order.filter { !shown.contains($0) }
    }

    /// The first book in the queue, when you've ordered it.
    static func upNext(in toRead: [ShelfEntry]) -> ShelfEntry? {
        guard !saved.isEmpty else { return nil }
        return apply(toRead).first
    }
}

/// A book on one or more of your shelves, found by the search pane.
struct LibraryMatch: Identifiable, Equatable {
    let entry: ShelfEntry
    let shelves: [String]
    var id: String { entry.bookID }

    /// Title/author matches across every shelf, one row per book.
    static func find(_ term: String, in library: [(shelf: Shelf, entries: [ShelfEntry])],
                     limit: Int = 8) -> [LibraryMatch] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return [] }
        var order: [String] = []
        var found: [String: (entry: ShelfEntry, shelves: [String])] = [:]
        for (shelf, entries) in library {
            for entry in entries where entry.matches(term) {
                if found[entry.bookID] == nil {
                    order.append(entry.bookID)
                    found[entry.bookID] = (entry, [])
                }
                found[entry.bookID]?.shelves.append(shelf.title)
            }
        }
        return order.prefix(limit).compactMap { id in
            found[id].map { LibraryMatch(entry: $0.entry, shelves: $0.shelves) }
        }
    }
}
