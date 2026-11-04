import Foundation
import SwiftUI
import UserNotifications

/// The series you're reading: how far you are in each, which book comes
/// next, and a notification when a new book joins one of them.
struct SeriesProgress: Codable, Sendable, Equatable, Identifiable {
    let title: String
    let url: URL
    /// The numbered books, in order (no novellas or box sets).
    let volumes: [GoodreadsSeries.Volume]
    /// Positions you've read.
    let read: [Double]
    let reading: [Double]
    /// The first numbered book you haven't read or started.
    let next: GoodreadsSeries.Volume?
    /// Whether that next book is on Want to Read already.
    let nextIsWanted: Bool

    var id: String { url.absoluteString }
    var isComplete: Bool { next == nil }
}

enum SeriesTracker {

    /// One series from its books and the ones of yours in it.
    static func progress(title: String, url: URL, volumes: [GoodreadsSeries.Volume],
                         readPositions: Set<Double>, readingPositions: Set<Double>,
                         shelvedIDs: Set<String>, shelvedTitles: Set<String>,
                         wantedIDs: Set<String>, wantedTitles: Set<String>) -> SeriesProgress {
        let numbered = volumes.filter { $0.position.map { $0.rounded() == $0 && $0 > 0 } ?? false }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        func isShelved(_ volume: GoodreadsSeries.Volume) -> Bool {
            shelvedIDs.contains(volume.bookID) || shelvedTitles.contains(Suggestions.normalizedTitle(volume.title))
        }
        // A book you read in another edition still counts, by title.
        let next = numbered.first { volume in
            guard let position = volume.position else { return false }
            return !readPositions.contains(position) && !readingPositions.contains(position)
                && !(isShelved(volume) && !wantedIDs.contains(volume.bookID)
                     && !wantedTitles.contains(Suggestions.normalizedTitle(volume.title)))
        }
        let wanted = next.map { wantedIDs.contains($0.bookID) || wantedTitles.contains(Suggestions.normalizedTitle($0.title)) } ?? false
        return SeriesProgress(title: title, url: url, volumes: numbered, read: readPositions.sorted(),
                              reading: readingPositions.sorted(), next: next, nextIsWanted: wanted)
    }

    /// Numbered books in `now` that weren't in `before`. Nothing when there
    /// was no `before`, so the first look is quiet.
    static func newVolumes(before: [String]?, now: [GoodreadsSeries.Volume]) -> [GoodreadsSeries.Volume] {
        guard let before else { return [] }
        let known = Set(before)
        return now.filter { !known.contains($0.bookID) }
    }

    static func notify(series: String, volume: GoodreadsSeries.Volume) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "New in \(series)")
        content.body = [volume.label, volume.title].filter { !$0.isEmpty }.joined(separator: " · ")
        content.sound = .default
        try? await UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: "series-\(volume.bookID)", content: content, trigger: nil))
    }
}

extension LibraryModel {
    /// Books' series come from their Goodreads pages, saved when they were
    /// opened or filled in for Stats; a few more are fetched each time.
    func loadSeries(force: Bool = false) async {
        if seriesProgress.isEmpty,
           let saved = await DataCache.shared.read([SeriesProgress].self, "series-progress", "all", ttl: .infinity) {
            seriesProgress = saved.value
        }
        if !force, let last = UserDefaults.standard.object(forKey: "seriesChecked") as? Date,
           Date().timeIntervalSince(last) < 24 * 3600, !seriesProgress.isEmpty { return }
        guard !isLoadingSeries else { return }
        isLoadingSeries = true
        defer { isLoadingSeries = false }

        let read = ShelfCache.read(.read)?.entries ?? []
        let reading = ShelfCache.read(.currentlyReading)?.entries ?? []
        let wanted = ShelfCache.read(.wantToRead)?.entries ?? []
        guard !read.isEmpty || !reading.isEmpty else { return }

        // Your books' series, from saved book pages; fetching the most
        // recently read ones that were never looked at, a few at a time.
        var looked = Set(UserDefaults.standard.stringArray(forKey: "seriesLookedUp") ?? [])
        var refs: [String: GoodreadsSeries.Ref] = [:]
        var toFetch: [ShelfEntry] = []
        let recentFirst = reading + read.sorted {
            (Suggestions.parseDate($0.dateRead ?? "") ?? .distantPast) > (Suggestions.parseDate($1.dateRead ?? "") ?? .distantPast)
        }
        for entry in recentFirst {
            if let detail = await DataCache.shared.read(GoodreadsBookPage.Detail.self, "book-page", entry.bookID, ttl: .infinity)?.value,
               detail.about != nil || detail.series != nil {
                refs[entry.bookID] = detail.series
            } else if !looked.contains(entry.bookID) {
                toFetch.append(entry)
            }
        }
        for entry in toFetch.prefix(force ? 40 : 15) where !Task.isCancelled {
            if let detail = try? await GoodreadsBookPage.fetch(bookID: entry.bookID) {
                await DataCache.shared.write(detail, "book-page", entry.bookID)
                refs[entry.bookID] = detail.series
            }
            looked.insert(entry.bookID)
        }
        UserDefaults.standard.set(Array(looked), forKey: "seriesLookedUp")

        let readIDs = Set(read.map(\.bookID))
        var bySeries: [URL: (title: String, read: Set<Double>, reading: Set<Double>, latest: Date)] = [:]
        for entry in recentFirst {
            guard let ref = refs[entry.bookID] else { continue }
            var item = bySeries[ref.url] ?? (ref.title, [], [], .distantPast)
            if let position = ref.position.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) {
                if readIDs.contains(entry.bookID) { item.read.insert(position) } else { item.reading.insert(position) }
            }
            let date = Suggestions.parseDate(entry.dateRead ?? "") ?? (readIDs.contains(entry.bookID) ? .distantPast : Date())
            item.latest = max(item.latest, date)
            bySeries[ref.url] = item
        }

        let all = read + reading + wanted
        let shelvedIDs = Set(all.map(\.bookID))
        let shelvedTitles = Set(all.map { Suggestions.normalizedTitle($0.title) })
        let wantedIDs = Set(wanted.map(\.bookID))
        let wantedTitles = Set(wanted.map { Suggestions.normalizedTitle($0.title) })
        var known = await DataCache.shared.read([String: [String]].self, "series-known", "all", ttl: .infinity)?.value ?? [:]

        var found: [SeriesProgress] = []
        for (url, item) in bySeries.sorted(by: { $0.value.latest > $1.value.latest }).prefix(25) where !Task.isCancelled {
            guard let volumes = try? await GoodreadsSeries.volumes(at: url), !volumes.isEmpty else { continue }
            let progress = SeriesTracker.progress(title: item.title, url: url, volumes: volumes,
                                                  readPositions: item.read, readingPositions: item.reading,
                                                  shelvedIDs: shelvedIDs, shelvedTitles: shelvedTitles,
                                                  wantedIDs: wantedIDs, wantedTitles: wantedTitles)
            if Preferences.shared.notifyNewReleases {
                for volume in SeriesTracker.newVolumes(before: known[url.absoluteString], now: progress.volumes).prefix(2) {
                    await SeriesTracker.notify(series: item.title, volume: volume)
                }
            }
            known[url.absoluteString] = progress.volumes.map(\.bookID)
            found.append(progress)
        }
        await DataCache.shared.write(known, "series-known", "all")
        // Series with something left to read first; finished ones after.
        seriesProgress = found.filter { !$0.isComplete } + found.filter(\.isComplete)
        await DataCache.shared.write(seriesProgress, "series-progress", "all")
        UserDefaults.standard.set(Date(), forKey: "seriesChecked")
    }
}

/// One series in Suggestions.
struct SeriesRow: View {
    let series: SeriesProgress
    @ObservedObject var model: LibraryModel

    var body: some View {
        HStack(spacing: 12) {
            if let next = series.next {
                Button { model.showBookDetail(next.asBook) } label: {
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
                    Text("Next: \(next.label) · \(next.title)")
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
                    let position = volume.position ?? 0
                    Circle()
                        .fill(series.read.contains(position) ? Color.green
                              : series.reading.contains(position) ? Color.orange : Color.secondary.opacity(0.25))
                        .frame(width: 7, height: 7)
                        .help("\(volume.label) · \(volume.title)")
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let next = series.next {
                if !series.nextIsWanted {
                    Button("Add “\(next.title)” to Want to Read") {
                        Task {
                            await model.shelve(next.asBook, to: .wantToRead)
                            await model.loadSeries(force: true)
                        }
                    }
                }
                Button("View Details…") { model.showBookDetail(next.asBook) }
            }
            Button("Open Series on Goodreads") { NSWorkspace.shared.open(series.url) }
        }
    }
}
