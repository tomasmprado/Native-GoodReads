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
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview && (saved?.reading.isEmpty ?? true) ? .sample : saved ?? .empty))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetStore.read() ?? .empty)
        // The app reloads the widget on every change; this is just a backstop.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(6 * 3600))))
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
        updated: Date()
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

    @ViewBuilder
    private func progress(_ book: WidgetSnapshot.Book) -> some View {
        ProgressView(value: Double(book.percent ?? 0), total: 100)
            .tint(.orange)
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
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
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
                        Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: min(1, Double(goal.read) / Double(goal.goal)))
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
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

@main
struct GoodreadsWidgets: WidgetBundle {
    var body: some Widget {
        ReadingWidget()
        GoalWidget()
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
