import AppKit
import SwiftUI

/// Time spent reading: sessions timed in the app, and the reading time a
/// Kobo keeps. Kept on this Mac; Goodreads has nowhere to put it.
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

    /// Pages an hour, from timed sessions that say where you started and
    /// stopped — the book's own when there's 20 minutes of it, else every book.
    static func pagesPerHour(_ records: [ReadingRecord], bookID: String? = nil) -> Double? {
        func rate(_ list: [ReadingRecord]) -> Double? {
            let timed = list.filter { $0.source == .timer && $0.pages != nil && $0.seconds >= 60 }
            let seconds = timed.reduce(0) { $0 + $1.seconds }
            let pages = timed.reduce(0) { $0 + ($1.pages ?? 0) }
            guard seconds >= 20 * 60, pages > 0 else { return nil }
            return Double(pages) / (Double(seconds) / 3600)
        }
        if let bookID, let own = rate(records.filter { $0.bookID == bookID }) { return own }
        return rate(records)
    }

    /// How long `pagesLeft` takes at `pagesPerHour`.
    static func timeLeft(pagesLeft: Int, pagesPerHour: Double) -> TimeInterval? {
        guard pagesLeft > 0, pagesPerHour > 0 else { return nil }
        return Double(pagesLeft) / pagesPerHour * 3600
    }

    /// Seconds read per day.
    static func secondsByDay(_ records: [ReadingRecord], calendar: Calendar = .current) -> [Date: Int] {
        var days: [Date: Int] = [:]
        for record in records { days[calendar.startOfDay(for: record.start), default: 0] += record.seconds }
        return days
    }

    /// Every day you read: a timed session, Kobo time, a day Apple Books
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

// MARK: - Timer

/// The reading session running now, if any — kept across launches.
@MainActor
final class SessionTimer: ObservableObject {
    static let shared = SessionTimer()

    struct Running: Codable, Equatable {
        let entry: ShelfEntry
        let started: Date
        /// The page you were on when you started, when the book's length is known.
        let startPage: Int?
        let startPercent: Int?
    }

    @Published private(set) var running: Running? {
        didSet {
            persist()
            WidgetBridge.scheduleUpdate()
        }
    }
    private static let key = "runningSession"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            running = try? JSONDecoder().decode(Running.self, from: data)
        }
    }

    private func persist() {
        if let running, let data = try? JSONEncoder().encode(running) {
            UserDefaults.standard.set(data, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }

    func isRunning(_ bookID: String) -> Bool { running?.entry.bookID == bookID }

    func start(_ entry: ShelfEntry) {
        let model = LibraryModel.shared
        let current = model.currentlyReading.first { $0.bookID == entry.bookID } ?? entry
        running = Running(entry: current, started: Date(), startPage: model.pages(for: current)?.page,
                          startPercent: current.progress)
    }

    /// Stops the clock and asks where you got to.
    func stop() {
        guard let running else { return }
        self.running = nil
        LibraryModel.shared.activeSheet = .endSession(running)
        WindowManager.shared.openMain?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() { running = nil }

    /// Saves the session that just ended, and the progress on Goodreads
    /// when it moved.
    func save(_ session: Running, ended: Date, endPage: Int?, endPercent: Int?, totalPages: Int?) async {
        let seconds = Int(ended.timeIntervalSince(session.started))
        guard seconds >= 30 else { return }
        var end = endPage
        if end == nil, let endPercent, let totalPages { end = Int((Double(totalPages) * Double(endPercent) / 100).rounded()) }
        await ReadingLog.add([ReadingRecord(bookID: session.entry.bookID, title: session.entry.title, start: session.started,
                                            seconds: seconds, startPage: session.startPage, endPage: end, source: .timer)])
        let model = LibraryModel.shared
        model.readingLog = await ReadingLog.all()
        let moved = endPage.map { $0 != session.startPage } ?? endPercent.map { $0 != session.startPercent } ?? false
        if moved {
            await model.updateProgress(session.entry, percent: endPage == nil ? endPercent : nil, page: endPage, note: "")
        }
    }

    /// goodreads-gui://session/start?book=<id> and goodreads-gui://session/stop, from the widget.
    func handle(_ url: URL) {
        let model = LibraryModel.shared
        WindowManager.shared.openMain?()
        NSApp.activate(ignoringOtherApps: true)
        if url.path == "/stop" {
            stop()
            return
        }
        guard running == nil else { return }
        let bookID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "book" }?.value
        let reading = model.currentlyReading.isEmpty ? (ShelfCache.read(.currentlyReading)?.entries ?? []) : model.currentlyReading
        if let entry = reading.first(where: { $0.bookID == bookID }) ?? reading.first {
            start(entry)
        }
    }
}

// MARK: - Views

/// The running session, along the bottom of the window.
struct SessionBar: View {
    @ObservedObject private var timer = SessionTimer.shared

    var body: some View {
        if let running = timer.running {
            HStack(spacing: 10) {
                Image(systemName: "timer").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(running.entry.title).appFont(size: 12, weight: .medium).lineLimit(1)
                    Text("Reading since \(running.started.formatted(date: .omitted, time: .shortened))")
                        .appFont(size: 10).foregroundStyle(.secondary)
                }
                Spacer()
                Text(running.started, style: .timer)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                Button("Stop") { timer.stop() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .glassButton()
                Button { timer.cancel() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Discard this session")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

/// After stopping: where you got to.
struct EndSessionSheet: View {
    let session: SessionTimer.Running
    let totalPages: Int?

    @Environment(\.dismiss) private var dismiss
    @State private var page = ""
    @State private var percent: Double
    @State private var ended = Date()

    init(session: SessionTimer.Running, totalPages: Int?) {
        self.session = session
        self.totalPages = totalPages
        _percent = State(initialValue: Double(session.startPercent ?? 0))
        _page = State(initialValue: session.startPage.map(String.init) ?? "")
    }

    private var seconds: TimeInterval { ended.timeIntervalSince(session.started) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.entry.title).appFont(size: 14, weight: .semibold).lineLimit(2)
                Text("You read for \(ReadingLog.duration(seconds)).").appFont(size: 12).foregroundStyle(.secondary)
            }
            if let totalPages {
                TextField(String(localized: "Page you’re on (of \(totalPages))"), text: $page)
                    .textFieldStyle(.roundedBorder)
                if let typed = Int(page), let start = session.startPage, typed > start, seconds >= 60 {
                    Text("\(typed - start) pages · \(Int((Double(typed - start) / (seconds / 3600)).rounded())) pages an hour")
                        .appFont(size: 11).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    Slider(value: $percent, in: 0...100, step: 1)
                    Text("\(Int(percent))%").font(.system(size: 12, weight: .medium).monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }
            }
            HStack {
                Button("Discard") { dismiss() }
                Spacer()
                Button("Save") {
                    let endPage = totalPages != nil ? Int(page) : nil
                    let endPercent = totalPages == nil ? Int(percent) : nil
                    Task { await SessionTimer.shared.save(session, ended: ended, endPage: endPage, endPercent: endPercent, totalPages: totalPages) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(totalPages != nil && Int(page) == nil)
            }
        }
        .padding(16)
        .frame(width: 340)
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
        let sessions = thisYear.filter { $0.source == .timer }.count
        let byDay = ReadingLog.secondsByDay(model.readingLog)
        let days = ReadingLog.readingDays(model.readingLog, progress: model.progressHistory)
        let pace = ReadingLog.pagesPerHour(model.readingLog)

        VStack(alignment: .leading, spacing: 12) {
            Text("Reading Time").appFont(size: 13, weight: .semibold)
            HStack(spacing: 24) {
                figure(seconds > 0 ? ReadingLog.duration(TimeInterval(seconds)) : "—", String(localized: "this year"))
                figure("\(sessions)", String(localized: "timed sessions"))
                figure(pace.map { "\(Int($0.rounded()))" } ?? "—", String(localized: "pages an hour"))
                figure("\(days.filter { calendar.component(.year, from: $0) == year }.count)", String(localized: "days read"))
            }
            calendarGrid(byDay: byDay, days: days, calendar: calendar)
            Text("From reading sessions you time here (▶ on Home), Kobo’s reading time, days a book was open in Apple Books, and progress updates.")
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
