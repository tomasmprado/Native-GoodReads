import Foundation
import SwiftUI
import UserNotifications

/// The series you're reading, from Google Books: how far you are in each,
/// which book comes next, and a notification when a new book joins one.
struct SeriesProgress: Codable, Sendable, Equatable, Identifiable {
    let seriesID: String
    let title: String
    /// The books in order, by their number in the series.
    let volumes: [Book]
    /// Numbers you've read.
    let read: [Double]
    let reading: [Double]
    /// The first book you haven't read or started.
    let next: Book?
    /// Whether that next book is on Want to Read already.
    let nextIsWanted: Bool

    var id: String { seriesID }
    var isComplete: Bool { next == nil }
    var url: URL? { URL(string: "https://play.google.com/store/books/series?id=\(seriesID)") }
}

enum SeriesTracker {

    /// One series from its books and yours in it. A book you have in
    /// another edition counts by title.
    static func progress(id: String, title: String, volumes: [Book],
                         readNumbers: Set<Double>, readingNumbers: Set<Double>,
                         shelvedTitles: Set<String>, wantedTitles: Set<String>) -> SeriesProgress {
        let numbered = volumes.filter { ($0.seriesNumber ?? 0) > 0 }.sorted { ($0.seriesNumber ?? 0) < ($1.seriesNumber ?? 0) }
        var read = readNumbers
        for volume in numbered {
            let name = Suggestions.normalizedTitle(volume.title)
            if shelvedTitles.contains(name), !wantedTitles.contains(name), let number = volume.seriesNumber,
               !readingNumbers.contains(number) {
                read.insert(number)
            }
        }
        let next = numbered.first { volume in
            guard let number = volume.seriesNumber else { return false }
            return !read.contains(number) && !readingNumbers.contains(number)
        }
        let wanted = next.map { wantedTitles.contains(Suggestions.normalizedTitle($0.title)) } ?? false
        return SeriesProgress(seriesID: id, title: title, volumes: numbered,
                              read: read.filter { number in numbered.contains { $0.seriesNumber == number } }.sorted(),
                              reading: readingNumbers.sorted(), next: next, nextIsWanted: wanted)
    }

    /// Books in `now` that weren't in `before`. Nothing when there was no
    /// `before`, so the first look is quiet.
    static func newVolumes(before: [String]?, now: [Book]) -> [Book] {
        guard let before else { return [] }
        let known = Set(before)
        return now.filter { !known.contains($0.id) }
    }

    static func notify(series: String, volume: Book) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "New in \(series)")
        content.body = [volume.seriesNumber.map { String(localized: "Book \(Int($0))") }, volume.title]
            .compactMap { $0 }.joined(separator: " · ")
        content.sound = .default
        try? await UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: "series-\(volume.id)", content: content, trigger: nil))
    }

    /// "Dune (Dune, #1)" → "Dune": the title a series name can be guessed from.
    static func bareTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*\([^()]*#[^()]*\)\s*$"#, with: "", options: .regularExpression)
    }
}

extension LibraryModel {
    /// Your books' series from Google Books — each book asked about once
    /// (then saved), a batch at a time — and each series' books.
    func loadSeries(force: Bool = false) async {
        if seriesProgress.isEmpty,
           let saved = await DataCache.shared.read([SeriesProgress].self, "google-series-progress", "all", ttl: .infinity) {
            seriesProgress = saved.value
        }
        if !force, let last = UserDefaults.standard.object(forKey: "googleSeriesChecked") as? Date,
           Date().timeIntervalSince(last) < 24 * 3600, !seriesProgress.isEmpty { return }
        guard !isLoadingSeries else { return }
        isLoadingSeries = true
        defer { isLoadingSeries = false }

        let read = ShelfCache.read(.read)?.entries ?? []
        let reading = ShelfCache.read(.currentlyReading)?.entries ?? []
        let wanted = ShelfCache.read(.wantToRead)?.entries ?? []
        guard !read.isEmpty || !reading.isEmpty else { return }

        let recentFirst = reading + read.sorted {
            (Suggestions.parseDate($0.dateRead ?? "") ?? .distantPast) > (Suggestions.parseDate($1.dateRead ?? "") ?? .distantPast)
        }
        let readIDs = Set(read.map(\.bookID))
        var bySeries: [String: (read: Set<Double>, reading: Set<Double>, latest: Date, example: String)] = [:]
        var asked = 0
        for entry in recentFirst where !Task.isCancelled {
            // Books already asked about are saved; only new ones cost a query.
            guard asked < (force ? 80 : 40) || bySeries.isEmpty else { break }
            asked += 1
            guard let found = await GoogleBooksClient.seriesOf(isbn: entry.isbn13 ?? entry.isbn,
                                                               title: SeriesTracker.bareTitle(entry.title), author: entry.author),
                  let id = found.seriesID, let number = found.seriesNumber else { continue }
            var item = bySeries[id] ?? ([], [], .distantPast, entry.title)
            if readIDs.contains(entry.bookID) { item.read.insert(number) } else { item.reading.insert(number) }
            let date = Suggestions.parseDate(entry.dateRead ?? "") ?? (readIDs.contains(entry.bookID) ? .distantPast : Date())
            item.latest = max(item.latest, date)
            bySeries[id] = item
        }

        let shelvedTitles = Set((read + reading + wanted).map { Suggestions.normalizedTitle(SeriesTracker.bareTitle($0.title)) })
        let wantedTitles = Set(wanted.map { Suggestions.normalizedTitle(SeriesTracker.bareTitle($0.title)) })
        var known = await DataCache.shared.read([String: [String]].self, "google-series-known", "all", ttl: .infinity)?.value ?? [:]

        var found: [SeriesProgress] = []
        for (id, item) in bySeries.sorted(by: { $0.value.latest > $1.value.latest }).prefix(25) where !Task.isCancelled {
            let series: (title: String?, books: [Book])
            if let hit = await DataCache.shared.read(SavedSeries.self, "google-series", id, ttl: DataCache.TTL.series), !hit.isStale {
                series = (hit.value.title, hit.value.books)
            } else if let fresh = try? await GoogleBooksClient.series(id: id), !fresh.books.isEmpty {
                await DataCache.shared.write(SavedSeries(title: fresh.title, books: fresh.books), "google-series", id)
                series = fresh
            } else {
                continue
            }
            let title = series.title ?? SeriesTracker.bareTitle(item.example)
            let progress = SeriesTracker.progress(id: id, title: title, volumes: series.books,
                                                  readNumbers: item.read, readingNumbers: item.reading,
                                                  shelvedTitles: shelvedTitles, wantedTitles: wantedTitles)
            if Preferences.shared.notifyNewReleases {
                for volume in SeriesTracker.newVolumes(before: known[id], now: progress.volumes).prefix(2) {
                    await SeriesTracker.notify(series: title, volume: volume)
                }
            }
            known[id] = progress.volumes.map(\.id)
            found.append(progress)
        }
        await DataCache.shared.write(known, "google-series-known", "all")
        // Series with something left to read first; finished ones after.
        seriesProgress = found.filter { !$0.isComplete } + found.filter(\.isComplete)
        await DataCache.shared.write(seriesProgress, "google-series-progress", "all")
        UserDefaults.standard.set(Date(), forKey: "googleSeriesChecked")
    }
}

struct SavedSeries: Codable, Sendable {
    let title: String?
    let books: [Book]
}

/// One series in Suggestions.
struct SeriesRow: View {
    let series: SeriesProgress
    @ObservedObject var model: LibraryModel

    var body: some View {
        HStack(spacing: 12) {
            if let next = series.next {
                Button { model.showBookDetail(next) } label: {
                    CachedAsyncImage(url: next.coverURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                        }
                    }
                    .frame(width: 34, height: 51)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "checkmark.seal.fill").appFont(size: 22).foregroundStyle(.green)
                    .frame(width: 34, height: 51)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(series.title).appFont(size: 13, weight: .medium).lineLimit(1)
                Text("Read \(series.read.count) of \(series.volumes.count)")
                    .appFont(size: 11).foregroundStyle(.secondary)
                if let next = series.next {
                    Text("Next: \(String(localized: "Book \(Int(next.seriesNumber ?? 0))")) · \(next.title)")
                        .appFont(size: 11).lineLimit(1)
                    if series.nextIsWanted {
                        Text("On Want to Read").appFont(size: 10).foregroundStyle(.secondary)
                    }
                } else {
                    Text("You’ve read them all.").appFont(size: 11).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(series.volumes.prefix(12)) { volume in
                    let position = volume.seriesNumber ?? 0
                    Circle()
                        .fill(series.read.contains(position) ? Color.green
                              : series.reading.contains(position) ? Color.orange : Color.secondary.opacity(0.25))
                        .frame(width: 7, height: 7)
                        .help("\(Int(position)) · \(volume.title)")
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let next = series.next {
                if !series.nextIsWanted {
                    Button("Add “\(next.title)” to Want to Read") {
                        Task {
                            await model.shelve(next, to: .wantToRead)
                            await model.loadSeries(force: true)
                        }
                    }
                }
                Button("View Details…") { model.showBookDetail(next) }
            }
            if let url = series.url {
                Button("Open Series in Google Play Books") { NSWorkspace.shared.open(url) }
            }
        }
    }
}
