import Foundation

// Shared between the app and its widget extension (build-app.sh compiles
// this file into both), so it uses nothing but Foundation.

/// What the widgets show, written by the app whenever it changes.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    struct Book: Codable, Equatable, Sendable, Identifiable {
        let bookID: String
        let title: String
        let author: String
        let percent: Int?
        let finishEstimate: Date?
        /// A file in `WidgetStore.folder`, when the cover was saved.
        let coverFile: String?
        /// The page that percentage is, and of how many — when known.
        var page: Int? = nil
        var totalPages: Int? = nil

        var id: String { bookID }
    }

    struct Goal: Codable, Equatable, Sendable {
        let year: Int
        let read: Int
        let goal: Int
        /// Books ahead of (positive) or behind (negative) an even pace.
        let ahead: Int
    }

    struct Quote: Codable, Equatable, Sendable {
        let text: String
        let title: String
        let author: String
    }

    struct Runner: Codable, Equatable, Sendable, Identifiable {
        let name: String
        let read: Int
        let goal: Int
        let isMe: Bool
        var id: String { name }
    }

    var reading: [Book]
    var goal: Goal?
    var updated: Date
    // Absent from snapshots saved before 3.1.
    /// Up to 100 of your saved quotes; the widget shows one a day.
    var quotes: [Quote]? = nil
    var race: [Runner]? = nil
    // Absent from snapshots saved before 3.2.
    var streak: ReadingStreak? = nil

    static let empty = WidgetSnapshot(reading: [], goal: nil, updated: .distantPast)

    /// Today's quote — the same all day, a different one tomorrow.
    func quote(on date: Date = Date(), calendar: Calendar = .current) -> Quote? {
        guard let quotes, !quotes.isEmpty else { return nil }
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        return quotes[day % quotes.count]
    }
}

/// Days in a row you've read, and this week's reading days against a
/// gentle goal. Saved as of the last day read, so whoever shows it (the app
/// or the widget, after midnight) works out "today" for itself.
struct ReadingStreak: Codable, Equatable, Sendable {
    /// The last day you read (its start).
    let lastDay: Date
    /// Days in a row ending on `lastDay`.
    let length: Int
    let longest: Int
    /// Days read this week (from the calendar's first weekday), and the goal.
    let weekDays: Int
    let weekGoal: Int
    /// The week `weekDays` counts, by its first day.
    let weekStart: Date

    static func compute(days: Set<Date>, weekGoal: Int, now: Date = Date(),
                        calendar: Calendar = .current) -> ReadingStreak? {
        let days = Set(days.map { calendar.startOfDay(for: $0) }).filter { $0 <= now }
        guard let last = days.max() else { return nil }
        func run(endingOn day: Date) -> Int {
            var count = 0
            var day = day
            while days.contains(day) {
                count += 1
                day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
            }
            return count
        }
        var longest = 0
        for day in days where !days.contains(calendar.date(byAdding: .day, value: 1, to: day) ?? day) {
            longest = max(longest, run(endingOn: day))
        }
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        return ReadingStreak(lastDay: last, length: run(endingOn: last), longest: longest,
                             weekDays: days.filter { $0 >= weekStart }.count, weekGoal: weekGoal,
                             weekStart: weekStart)
    }

    /// Whether you've read today.
    func readToday(on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.isDate(lastDay, inSameDayAs: date)
    }

    /// The streak as it stands on `date`: still alive the day after the
    /// last day read (there's still today to read), gone after that.
    func current(on date: Date = Date(), calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: date)
        let gap = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastDay), to: today).day ?? 99
        return gap <= 1 ? length : 0
    }

    /// Days read this week as of `date` (none yet when a new week started).
    func daysThisWeek(on date: Date = Date(), calendar: Calendar = .current) -> Int {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        return calendar.isDate(start, inSameDayAs: weekStart) ? weekDays : 0
    }

    /// Whether the streak is alive but needs reading today to carry on.
    func atRisk(on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        current(on: date, calendar: calendar) > 0 && !readToday(on: date, calendar: calendar)
    }
}

enum WidgetStore {
    /// The widget is sandboxed, so this is spelled out from the real home
    /// folder (a sandboxed process's own home is its container), and the
    /// widget's entitlements allow reading exactly this folder.
    static var folder: URL {
        URL(fileURLWithPath: realHome, isDirectory: true)
            .appendingPathComponent("Library/Application Support/GoodreadsGUI/widget", isDirectory: true)
    }

    static var snapshotFile: URL { folder.appendingPathComponent("snapshot.json") }

    private static var realHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    static func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    static func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: snapshotFile, options: .atomic)
    }

    static let kindReading = "local.goodreads.gui.reading"
    static let kindGoal = "local.goodreads.gui.goal"
    static let kindQuote = "local.goodreads.gui.quote"
    static let kindRace = "local.goodreads.gui.race"
    static let kindStreak = "local.goodreads.gui.streak"
}
