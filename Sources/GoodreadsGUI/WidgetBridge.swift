import AppKit
import WidgetKit

/// Keeps the widgets' snapshot in step with the app: Currently Reading with
/// progress, finish estimates and covers, and this year's goal.
@MainActor
enum WidgetBridge {
    private static var pending: Task<Void, Never>?
    private static var lastWritten: WidgetSnapshot?

    /// Coalesces bursts of changes (a shelf reload touches several values).
    static func scheduleUpdate() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await update()
        }
    }

    static func update() async {
        let model = LibraryModel.shared
        let reading = model.currentlyReading.isEmpty
            ? (ShelfCache.read(.currentlyReading)?.entries ?? [])
            : model.currentlyReading

        var books: [WidgetSnapshot.Book] = []
        for entry in reading.prefix(6) {
            let pages = model.pages(for: entry)
            books.append(.init(bookID: entry.bookID, title: entry.title, author: entry.author,
                               percent: entry.progress, finishEstimate: model.finishEstimate(for: entry),
                               coverFile: await saveCover(entry), page: pages?.page, totalPages: pages?.total))
        }

        let year = Calendar.current.component(.year, from: Date())
        let stats = model.readingStats
            ?? ShelfCache.read(.read).map { ReadingStats.compute(from: $0.entries, extras: [:]) }
        let goalCount = Preferences.shared.yearlyGoal
        let goal = stats.map { stats in
            WidgetSnapshot.Goal(year: year, read: max(model.readThisYear, stats.readThisYear), goal: goalCount,
                                ahead: max(model.readThisYear, stats.readThisYear) - ReadingStats.expectedByToday(goal: goalCount))
        }

        var snapshot = WidgetSnapshot(reading: books, goal: goal, updated: Date())
        snapshot.quotes = await savedQuotes(shelves: reading + (ShelfCache.read(.read)?.entries ?? []))
        snapshot.race = model.race.prefix(6).map { .init(name: $0.name, read: $0.read, goal: $0.goal, isMe: $0.isMe) }
        if var last = lastWritten {
            last.updated = snapshot.updated
            if last == snapshot { return }
        }
        do {
            try WidgetStore.write(snapshot)
            removeUnusedCovers(keeping: Set(books.compactMap(\.coverFile)))
            lastWritten = snapshot
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            Diagnostics.shared.log("widget", "couldn’t save: \(error.localizedDescription)", ok: false)
        }
    }

    /// Your saved quotes, in a steady order, for the Quote of the Day widget.
    private static func savedQuotes(shelves: [ShelfEntry]) async -> [WidgetSnapshot.Quote] {
        let books = QuoteLibrary.books(notes: await BookNotes.all(), shelves: shelves)
        return books.flatMap { book in book.quotes.map { WidgetSnapshot.Quote(text: $0.text, title: book.title, author: book.author) } }
            .filter { $0.text.count <= 600 }
            .sorted { $0.text < $1.text }
            .prefix(100).map { $0 }
    }

    /// A small JPEG of the cover next to the snapshot, so the sandboxed
    /// widget doesn't need the network.
    private static func saveCover(_ entry: ShelfEntry) async -> String? {
        let name = "cover-\(entry.bookID).jpg"
        let file = WidgetStore.folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) { return name }
        guard let url = entry.coverURL, let image = await ImageMemoryCache.shared.load(url) else { return nil }

        let height: CGFloat = 180
        let width = max(1, (image.size.width / max(image.size.height, 1)) * height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        try? FileManager.default.createDirectory(at: WidgetStore.folder, withIntermediateDirectories: true)
        return (try? data.write(to: file, options: .atomic)) != nil ? name : nil
    }

    private static func removeUnusedCovers(keeping kept: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: WidgetStore.folder.path)) ?? []
        for file in files where file.hasPrefix("cover-") && !kept.contains(file) {
            try? FileManager.default.removeItem(at: WidgetStore.folder.appendingPathComponent(file))
        }
    }
}
