import Foundation

/// Shelves are cached to disk so opening one is instant. The network fetch
/// still happens, in the background — the cache decides what you look at while
/// it runs, not whether it runs.
enum ShelfCache {

    private static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GoodreadsGUI/shelves", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func file(for shelf: Shelf) -> URL {
        // Slugs can contain anything a user typed; don't trust them as paths.
        let safe = shelf.name.replacingOccurrences(
            of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression
        )
        // The blanket replace above can collapse two different names to the
        // same prefix (e.g. "sci fi" and "sci_fi") — a hash of the original,
        // un-sanitized name keeps them apart. FNV-1a rather than
        // `String.hashValue`, which is randomized per process launch and
        // would make the cache miss on every run.
        return folder.appendingPathComponent("\(safe)-\(stableHash(shelf.name)).json")
    }

    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016x", hash)
    }

    struct Cached: Codable {
        let entries: [ShelfEntry]
        let fetched: Date
    }

    static func read(_ shelf: Shelf) -> Cached? {
        guard let data = try? Data(contentsOf: file(for: shelf)),
              let cached = try? JSONDecoder().decode(Cached.self, from: data) else { return nil }
        return Cached(entries: ShelfTitles.apply(cached.entries), fetched: cached.fetched)
    }

    static func write(_ entries: [ShelfEntry], for shelf: Shelf) {
        let payload = Cached(entries: entries, fetched: Date())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: file(for: shelf), options: .atomic)
        SpotlightIndex.update(entries, shelf: shelf)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: folder)
        ShelfTitles.clear()
        SpotlightIndex.removeAll()
    }

    /// Every cached own-shelf entry for this book, from any shelf on disk.
    static func entry(bookID: String) -> ShelfEntry? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return nil }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let cached = try? JSONDecoder().decode(Cached.self, from: data),
                  let hit = cached.entries.first(where: { $0.bookID == bookID }) else { continue }
            return ShelfTitles.apply([hit])[0]
        }
        return nil
    }

    /// How long a cached copy is trusted without a background refresh — the
    /// cache used to never expire on its own (README's own "Limits worth
    /// knowing"), which meant Home could show a Currently Reading carousel or
    /// suggestion set from days ago until something else happened to trigger
    /// a reload.
    static let defaultTTL: TimeInterval = 6 * 3600

    static func isStale(_ date: Date, ttl: TimeInterval = defaultTTL) -> Bool {
        Date().timeIntervalSince(date) > ttl
    }

    static func age(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60:     return String(localized: "just now")
        case ..<3600:   return String(localized: "\(seconds / 60)m ago")
        case ..<86400:  return String(localized: "\(seconds / 3600)h ago")
        default:        return String(localized: "\(seconds / 86400)d ago")
        }
    }
}
