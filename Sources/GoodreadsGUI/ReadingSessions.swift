import SwiftUI

/// Time spent reading, from the reading time a Kobo keeps and the days a
/// book was open in Apple Books. Kept on this Mac.
struct ReadingRecord: Codable, Sendable, Equatable, Identifiable {
    enum Source: String, Codable, Sendable { case timer, kobo, appleBooks }

    var id = UUID()
    /// The Goodreads book id, when the book is on your shelves.
    let bookID: String?
    let title: String
    let start: Date
    let seconds: Int
    var startPage: Int? = nil
    var endPage: Int? = nil
    let source: Source

    var pages: Int? {
        guard let startPage, let endPage, endPage > startPage else { return nil }
        return endPage - startPage
    }
}

enum ReadingLog {
    private static let namespace = "reading-log"
    private static let key = "all"

    static func all() async -> [ReadingRecord] {
        await DataCache.shared.read([ReadingRecord].self, namespace, key, ttl: .infinity)?.value ?? []
    }

    static func add(_ records: [ReadingRecord]) async {
        guard !records.isEmpty else { return }
        await DataCache.shared.modify([ReadingRecord].self, namespace, key, default: []) { all in
            all.append(contentsOf: records)
            all.sort { $0.start < $1.start }
        }
    }

    /// Seconds read per day.
    static func secondsByDay(_ records: [ReadingRecord], calendar: Calendar = .current) -> [Date: Int] {
        var days: [Date: Int] = [:]
        for record in records { days[calendar.startOfDay(for: record.start), default: 0] += record.seconds }
        return days
    }

    /// Every day you read: Kobo time, a day Apple Books
    /// was opened on a book, or a progress update.
    static func readingDays(_ records: [ReadingRecord], progress: [String: [ProgressPoint]],
                            calendar: Calendar = .current) -> Set<Date> {
        var days = Set(records.map { calendar.startOfDay(for: $0.start) })
        for points in progress.values { for point in points { days.insert(calendar.startOfDay(for: point.date)) } }
        return days
    }

    /// "1 h 20 min", "45 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: max(60, seconds)) ?? ""
    }

    // MARK: Reading apps

    private static let koboTotalsKey = "koboTimeTotals"
    private static let appleBooksDaysKey = "appleBooksReadingDays"

    /// Kobo keeps a running total of reading time per book; what's new
    /// since the last look becomes a record on the day it was last read.
    /// The first look brings the whole total in.
    static func koboRecords(_ books: [ReaderBook], matches: [String: ShelfEntry],
                            previous: [String: Int]) -> (records: [ReadingRecord], totals: [String: Int]) {
        var totals = previous
        var records: [ReadingRecord] = []
        for book in books where book.source == .kobo {
            guard let total = book.secondsRead, total > 0 else { continue }
            let delta = total - (previous[book.sourceID] ?? 0)
            totals[book.sourceID] = total
            guard delta >= 60 else { continue }
            records.append(ReadingRecord(bookID: matches[book.id]?.bookID, title: book.title,
                                         start: book.lastOpened ?? Date(), seconds: delta, source: .kobo))
        }
        return (records, totals)
    }

    /// Apple Books keeps no reading time, only when a book was last opened:
    /// each new day becomes a record with no time, so the calendar shows it.
    static func appleBooksRecords(_ books: [ReaderBook], matches: [String: ShelfEntry],
                                  seen: Set<String>, calendar: Calendar = .current) -> (records: [ReadingRecord], seen: Set<String>) {
        var seen = seen
        var records: [ReadingRecord] = []
        let formatter = ISO8601DateFormatter()
        for book in books where book.source == .appleBooks {
            guard let opened = book.lastOpened else { continue }
            let key = "\(book.sourceID)@\(formatter.string(from: calendar.startOfDay(for: opened)))"
            guard seen.insert(key).inserted else { continue }
            records.append(ReadingRecord(bookID: matches[book.id]?.bookID, title: book.title, start: opened,
                                         seconds: 0, source: .appleBooks))
        }
        return (records, seen)
    }

    /// Called after every reading-apps scan.
    static func importReaderTime(_ books: [ReaderBook], matches: [String: ShelfEntry]) async {
        let defaults = UserDefaults.standard
        let kobo = koboRecords(books, matches: matches,
                               previous: defaults.dictionary(forKey: koboTotalsKey) as? [String: Int] ?? [:])
        defaults.set(kobo.totals, forKey: koboTotalsKey)
        let firstAppleLook = defaults.object(forKey: appleBooksDaysKey) == nil
        let apple = appleBooksRecords(books, matches: matches,
                                      seen: Set(defaults.stringArray(forKey: appleBooksDaysKey) ?? []))
        defaults.set(Array(apple.seen), forKey: appleBooksDaysKey)
        // Only the last-opened day is known, so the first look can't tell
        // anything useful about the past beyond that one day per book.
        await add(kobo.records + (firstAppleLook ? apple.records.filter { Date().timeIntervalSince($0.start) < 30 * 86400 } : apple.records))
    }
}

/// Stats: time spent reading this year, your pace, and a calendar of the
/// days you read.
struct ReadingTimeCard: View {
    @ObservedObject var model: LibraryModel
    private let weeks = 26

    var body: some View {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        let thisYear = model.readingLog.filter { calendar.component(.year, from: $0.start) == year }
        let seconds = thisYear.reduce(0) { $0 + $1.seconds }
        let byDay = ReadingLog.secondsByDay(model.readingLog)
        let days = ReadingLog.readingDays(model.readingLog, progress: model.progressHistory)

        VStack(alignment: .leading, spacing: 12) {
            Text("Reading Time").appFont(size: 13, weight: .semibold)
            HStack(spacing: 24) {
                figure(seconds > 0 ? ReadingLog.duration(TimeInterval(seconds)) : "—", String(localized: "this year"))
                figure("\(days.filter { calendar.component(.year, from: $0) == year }.count)", String(localized: "days read"))
            }
            calendarGrid(byDay: byDay, days: days, calendar: calendar)
            Text("From Kobo’s reading time, the days a book was open in Apple Books, and your progress updates.")
                .appFont(size: 11).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18)
        .task { if model.readingLog.isEmpty { model.readingLog = await ReadingLog.all() } }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).appFont(size: 18, weight: .semibold)
            Text(label).appFont(size: 11).foregroundStyle(.secondary)
        }
    }

    /// The last 26 weeks, a column a week, Monday at the top.
    private func calendarGrid(byDay: [Date: Int], days: Set<Date>, calendar: Calendar) -> some View {
        let today = calendar.startOfDay(for: Date())
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7      // Monday = 0
        let firstMonday = calendar.date(byAdding: .day, value: -weekday - (weeks - 1) * 7, to: today) ?? today
        return HStack(alignment: .top, spacing: 3) {
            ForEach(0..<weeks, id: \.self) { week in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { day in
                        let date = calendar.date(byAdding: .day, value: week * 7 + day, to: firstMonday) ?? today
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(seconds: byDay[date] ?? 0, read: days.contains(date), future: date > today))
                            .frame(width: 11, height: 11)
                            .help(tooltip(date, seconds: byDay[date] ?? 0, read: days.contains(date)))
                    }
                }
            }
        }
        .accessibilityLabel(Text("Days you read in the last six months"))
    }

    private func color(seconds: Int, read: Bool, future: Bool) -> Color {
        if future { return .clear }
        guard read || seconds > 0 else { return Color.secondary.opacity(0.15) }
        switch seconds {
        case 0..<900:    return Color.green.opacity(0.35)
        case 900..<2700: return Color.green.opacity(0.6)
        default:         return Color.green
        }
    }

    private func tooltip(_ date: Date, seconds: Int, read: Bool) -> String {
        let day = date.formatted(date: .abbreviated, time: .omitted)
        if seconds >= 60 { return "\(day) · \(ReadingLog.duration(TimeInterval(seconds)))" }
        return read ? "\(day) · \(String(localized: "read"))" : day
    }
}
