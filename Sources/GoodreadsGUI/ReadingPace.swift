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
    /// Where a percentage lands in a book of `total` pages, and how fast
    /// you've been going.
    struct Pages: Equatable {
        let page: Int
        let total: Int
        var left: Int { max(0, total - page) }
        /// Pages a day so far, when there's enough history to tell.
        let perDay: Double?
    }

    static func pages(percent: Int, total: Int, history: [ProgressPoint],
                      startedOn: Date? = nil) -> Pages? {
        guard total > 0, (0...100).contains(percent) else { return nil }
        let page = Int((Double(total) * Double(percent) / 100).rounded())
        var perDay: Double?
        if let last = history.last, var first = history.first {
            if let startedOn, startedOn < first.date, first.percent > 0 {
                first = ProgressPoint(date: startedOn, percent: 0)
            }
            let days = last.date.timeIntervalSince(first.date) / 86400
            let gained = Double(last.percent - first.percent)
            if days >= 1, gained > 0 { perDay = Double(total) * gained / 100 / days }
        }
        return Pages(page: page, total: total, perDay: perDay)
    }

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

/// "Finish by" dates you set for books you're reading, and how many pages
/// a day that takes from where you are.
enum FinishPlans {
    private static let key = "finishPlans"

    static var all: [String: Date] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:])
            .mapValues { Date(timeIntervalSince1970: $0) }
    }

    static func date(for bookID: String) -> Date? { all[bookID] }

    static func set(_ date: Date?, for bookID: String) {
        var plans = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        plans[bookID] = date?.timeIntervalSince1970
        UserDefaults.standard.set(plans, forKey: key)
    }

    /// Pages a day from today to `date` (counting today), at least 1 when anything's left.
    static func pagesPerDay(left: Int, by date: Date, now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard left > 0 else { return 0 }
        let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                            to: calendar.startOfDay(for: date)).day ?? 0) + 1
        guard days > 0 else { return nil }
        return max(1, Int((Double(left) / Double(days)).rounded(.up)))
    }
}
