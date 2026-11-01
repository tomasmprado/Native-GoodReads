import Foundation

/// Your reading progress over time, kept on this Mac — Goodreads shows only
/// the latest update — and the finish date it points to.
struct ProgressPoint: Codable, Sendable, Equatable {
    let date: Date
    let percent: Int
}

enum ReadingPace {

    private static let namespace = "progress-history"
    private static let key = "all"

    static func all() async -> [String: [ProgressPoint]] {
        await DataCache.shared.read([String: [ProgressPoint]].self, namespace, key, ttl: .infinity)?.value ?? [:]
    }

    /// Adds today's reading for a book; a second update the same day
    /// replaces the first.
    static func record(_ percent: Int, for bookID: String, on date: Date = Date()) async {
        await DataCache.shared.modify([String: [ProgressPoint]].self, namespace, key, default: [:]) { all in
            all[bookID] = adding(ProgressPoint(date: date, percent: percent), to: all[bookID] ?? [])
        }
    }

    static func adding(_ point: ProgressPoint, to history: [ProgressPoint],
                       calendar: Calendar = .current) -> [ProgressPoint] {
        var points = history.filter { !calendar.isDate($0.date, inSameDayAs: point.date) }
        // Starting over (a reread, or a mistaken update) begins a new history.
        if let last = points.last, point.percent < last.percent { points = [] }
        points.append(point)
        return points.sorted { $0.date < $1.date }
    }

    /// When the book will be done at the pace so far: from the first point
    /// (or the day it was shelved, at 0%) to the latest. Nil when there's
    /// not enough to go on — under a day of history, or no progress made.
    static func estimate(_ history: [ProgressPoint], startedOn: Date? = nil, now: Date = Date()) -> Date? {
        guard let last = history.last, last.percent < 100 else { return nil }
        guard var first = history.first else { return nil }
        // The day it went on Currently Reading is a fair 0% starting point.
        if let startedOn, startedOn < first.date, first.percent > 0 {
            first = ProgressPoint(date: startedOn, percent: 0)
        }
        let days = last.date.timeIntervalSince(first.date) / 86400
        let gained = Double(last.percent - first.percent)
        guard days >= 1, gained > 0 else { return nil }

        let remainingDays = Double(100 - last.percent) / (gained / days)
        guard remainingDays < 3 * 365 else { return nil }
        return max(now, last.date.addingTimeInterval(remainingDays * 86400))
    }
}
