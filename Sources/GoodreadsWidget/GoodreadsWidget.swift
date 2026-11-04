import SwiftUI
import WidgetKit

// The desktop and Notification Center widgets. They show what the app last
// saved (see WidgetData.swift); the app asks for a reload whenever that changes.

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let saved = WidgetStore.read()
        let preview = context.isPreview && (saved?.reading.isEmpty ?? true) && (saved?.quotes ?? []).isEmpty
        completion(SnapshotEntry(date: Date(), snapshot: preview ? .sample : saved ?? .empty))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetStore.read() ?? .empty
        // The app reloads the widget on every change; this is just a backstop,
        // plus a fresh entry at midnight for the next day's quote.
        let midnight = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
        let entries = [SnapshotEntry(date: Date(), snapshot: snapshot), SnapshotEntry(date: midnight, snapshot: snapshot)]
        completion(Timeline(entries: entries, policy: .after(min(midnight, Date().addingTimeInterval(6 * 3600)))))
    }
}

extension WidgetSnapshot {
    static let sample = WidgetSnapshot(
        reading: [
            .init(bookID: "1", title: "Dune", author: "Frank Herbert", percent: 42,
                  finishEstimate: Date().addingTimeInterval(9 * 86400), coverFile: nil),
            .init(bookID: "2", title: "Middlemarch", author: "George Eliot", percent: 15,
                  finishEstimate: nil, coverFile: nil),
        ],
        goal: .init(year: Calendar.current.component(.year, from: Date()), read: 18, goal: 24, ahead: 1),
        updated: Date(),
        quotes: [.init(text: "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.",
                       title: "Pride and Prejudice", author: "Jane Austen")],
        race: [.init(name: "Ana", read: 21, goal: 30, isMe: false), .init(name: "You", read: 18, goal: 24, isMe: true),
               .init(name: "Rui", read: 9, goal: 20, isMe: false)]
    )
}

// MARK: - Currently Reading

struct ReadingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        let books = entry.snapshot.reading
        Group {
            if books.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "book.closed").font(.title2).foregroundStyle(.secondary)
                    Text("Nothing on Currently Reading").font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if family == .systemSmall {
                small(books[0])
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Currently Reading").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(books.prefix(family == .systemLarge ? 6 : 2)) { row($0) }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackground()
    }

    private func small(_ book: WidgetSnapshot.Book) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                cover(book).frame(width: 40, height: 60)
                Spacer()
                if let percent = book.percent {
                    Text("\(percent)%").font(.system(size: 20, weight: .bold, design: .rounded))
                }
            }
            Spacer(minLength: 0)
            Text(book.title).font(.caption.weight(.semibold)).lineLimit(2)
            progress(book)
        }
    }

    private func row(_ book: WidgetSnapshot.Book) -> some View {
        HStack(spacing: 8) {
            cover(book).frame(width: 30, height: 45)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(detail(book)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                progress(book)
            }
        }
    }

    private func progress(_ book: WidgetSnapshot.Book) -> some View {
        ProgressBar(fraction: Double(book.percent ?? 0) / 100)
    }

    private func detail(_ book: WidgetSnapshot.Book) -> String {
        var bits = [book.author]
        if let page = book.page, let total = book.totalPages {
            bits.append(String(localized: "p. \(page) of \(total)"))
        } else if let percent = book.percent {
            bits.append("\(percent)%")
        }
        if let estimate = book.finishEstimate {
            bits.append(String(localized: "done around \(estimate.formatted(.dateTime.day().month(.abbreviated)))"))
        }
        return bits.joined(separator: " · ")
    }

    @ViewBuilder
    private func cover(_ book: WidgetSnapshot.Book) -> some View {
        if let file = book.coverFile,
           let image = NSImage(contentsOf: WidgetStore.folder.appendingPathComponent(file)) {
            CoverImage(image: image)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2))
                .overlay(Image(systemName: "book.closed").font(.caption2).foregroundStyle(.secondary))
        }
    }
}

struct ReadingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.kindReading, provider: SnapshotProvider()) { entry in
            ReadingWidgetView(entry: entry)
        }
        .configurationDisplayName("Currently Reading")
        .description("Your books in progress, and when you’ll finish them.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Reading Goal

struct GoalWidgetView: View {
    let entry: SnapshotEntry

    var body: some View {
        Group {
            if let goal = entry.snapshot.goal, goal.goal > 0 {
                VStack(spacing: 6) {
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.15), lineWidth: 8)
                        GoalRing(fraction: min(1, Double(goal.read) / Double(goal.goal)))
                        VStack(spacing: 0) {
                            Text("\(goal.read)").font(.system(size: 24, weight: .bold, design: .rounded))
                            Text("of \(goal.goal)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    Text(pace(goal))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(goal.ahead >= 0 ? Color.green : Color.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "target").font(.title2).foregroundStyle(.secondary)
                    Text("Open the app to see your goal").font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetBackground()
    }

    private func pace(_ goal: WidgetSnapshot.Goal) -> String {
        if goal.read >= goal.goal { return String(localized: "Goal reached 🎉") }
        return goal.ahead >= 0 ? String(localized: "\(goal.ahead) ahead of schedule")
                               : String(localized: "\(-goal.ahead) behind schedule")
    }
}

struct GoalWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.kindGoal, provider: SnapshotProvider()) { entry in
            GoalWidgetView(entry: entry)
        }
        .configurationDisplayName("Reading Goal")
        .description("Books read this year against your goal.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Quote of the Day

struct QuoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        Group {
            if let quote = entry.snapshot.quote(on: entry.date) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "quote.opening").font(.caption).foregroundStyle(.orange).widgetAccentable()
                    Text(quote.text)
                        .font(.system(size: family == .systemSmall ? 12 : 14, design: .serif))
                        .lineLimit(family == .systemLarge ? 14 : family == .systemMedium ? 5 : 6)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Text([quote.title, quote.author].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "quote.opening").font(.title2).foregroundStyle(.secondary)
                    Text("Save quotes in a book’s notes and one shows here each day")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackground()
    }
}

struct QuoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.kindQuote, provider: SnapshotProvider()) { entry in
            QuoteWidgetView(entry: entry)
        }
        .configurationDisplayName("Quote of the Day")
        .description("One of the quotes you saved, a different one each day.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Friends' Race

struct RaceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        let runners = entry.snapshot.race ?? []
        Group {
            if runners.count < 2 {
                VStack(spacing: 6) {
                    Image(systemName: "flag.checkered").font(.title2).foregroundStyle(.secondary)
                    Text("Open Home in the app to see the race with your friends")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Reading Challenge").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(runners.prefix(family == .systemLarge ? 6 : 3)) { runner in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(runner.name).font(.caption.weight(runner.isMe ? .bold : .regular)).lineLimit(1)
                                Spacer()
                                Text("\(runner.read)/\(runner.goal)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            ProgressBar(fraction: runner.goal > 0 ? Double(runner.read) / Double(runner.goal) : 0)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackground()
    }
}

struct RaceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.kindRace, provider: SnapshotProvider()) { entry in
            RaceWidgetView(entry: entry)
        }
        .configurationDisplayName("Friends’ Race")
        .description("You and your friends in this year’s Reading Challenge.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct GoodreadsWidgets: WidgetBundle {
    var body: some Widget {
        ReadingWidget()
        GoalWidget()
        QuoteWidget()
        RaceWidget()
    }
}

// MARK: - Glass and tinted widgets

// On the macOS 26 desktop, widgets are often drawn in one colour (Liquid
// Glass, or tinted): images turn into flat shapes and every colour becomes
// the same, so an ordinary progress bar's track and fill can't be told apart.
// These keep covers as pictures and the filled part distinct in every mode.

/// A cover that stays a picture when the widget is tinted.
struct CoverImage: View {
    let image: NSImage

    var body: some View {
        if #available(macOS 15, *) {
            Image(nsImage: image)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .aspectRatio(contentMode: .fill)
        } else {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        }
    }
}

/// A thin bar whose filled part stands out in colour, tinted and glass widgets.
struct ProgressBar: View {
    let fraction: Double
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.18))
                Capsule()
                    .fill(renderingMode == .fullColor ? Color.orange : Color.primary)
                    .frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
                    .widgetAccentable()
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel(Text("\(Int((fraction * 100).rounded()))%"))
    }
}

struct GoalRing: View {
    let fraction: Double
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Circle()
            .trim(from: 0, to: fraction)
            .stroke(renderingMode == .fullColor ? Color.orange : Color.primary,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .widgetAccentable()
    }
}

extension View {
    /// macOS 14 wants the background declared this way; 13 just draws it.
    @ViewBuilder
    func widgetBackground() -> some View {
        if #available(macOS 14, *) {
            containerBackground(.fill.tertiary, for: .widget)
        } else {
            padding().background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
