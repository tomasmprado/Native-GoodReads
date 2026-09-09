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
        guard let data = try? Data(contentsOf: file(for: shelf)) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }

    static func write(_ entries: [ShelfEntry], for shelf: Shelf) {
        let payload = Cached(entries: entries, fetched: Date())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: file(for: shelf), options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: folder)
    }

    static func age(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60:     return "just now"
        case ..<3600:   return "\(seconds / 60)m ago"
        case ..<86400:  return "\(seconds / 3600)h ago"
        default:        return "\(seconds / 86400)d ago"
        }
    }
}
