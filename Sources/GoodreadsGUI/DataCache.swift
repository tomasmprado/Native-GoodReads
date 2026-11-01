import AppKit
import SwiftUI

/// Everything the app fetches besides shelves (which have `ShelfCache`) —
/// book pages, author pages, friends, profiles, suggestions, author searches.
/// Kept in memory for the session and on disk across launches, so a screen
/// you've seen before opens instantly and refreshes behind what you see.
actor DataCache {
    static let shared = DataCache()

    struct Hit<T> {
        let value: T
        let fetched: Date
        let isStale: Bool
    }

    private struct Stored<T: Codable>: Codable {
        let value: T
        let fetched: Date
    }

    private var memory: [String: (value: Any, fetched: Date)] = [:]

    private static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GoodreadsGUI/cache", isDirectory: true)
    }()

    func read<T: Codable>(_ type: T.Type, _ namespace: String, _ key: String,
                          ttl: TimeInterval) -> Hit<T>? {
        let id = "\(namespace)/\(key)"
        if let hit = memory[id], let value = hit.value as? T {
            return Hit(value: value, fetched: hit.fetched, isStale: Self.isStale(hit.fetched, ttl))
        }
        guard let data = try? Data(contentsOf: Self.file(namespace, key)),
              let stored = try? JSONDecoder().decode(Stored<T>.self, from: data) else { return nil }
        memory[id] = (stored.value, stored.fetched)
        return Hit(value: stored.value, fetched: stored.fetched, isStale: Self.isStale(stored.fetched, ttl))
    }

    func write<T: Codable>(_ value: T, _ namespace: String, _ key: String) {
        let now = Date()
        memory["\(namespace)/\(key)"] = (value, now)
        let file = Self.file(namespace, key)
        guard let data = try? JSONEncoder().encode(Stored(value: value, fetched: now)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Signing out drops everything — it all belongs to the old account.
    func clear() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: Self.folder)
    }

    private static func isStale(_ date: Date, _ ttl: TimeInterval) -> Bool {
        Date().timeIntervalSince(date) > ttl
    }

    private static func file(_ namespace: String, _ key: String) -> URL {
        folder.appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("\(stableHash(key)).json")
    }

    /// FNV-1a — `hashValue` changes every launch, which would miss the disk cache.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016x", hash)
    }

    /// Stale-while-revalidate: hands `show` the cached copy right away, then
    /// fetches when there's no copy, it's past `ttl`, or `force` is set, and
    /// hands `show` the fresh value. A failed refresh keeps the cached copy on
    /// screen and only throws when there was nothing cached to show.
    nonisolated static func load<T: Codable>(
        _ namespace: String, _ key: String,
        ttl: TimeInterval, force: Bool = false,
        fetch: @escaping () async throws -> T,
        show: @MainActor @escaping (T, _ fromCache: Bool) -> Void
    ) async throws {
        let hit = await shared.read(T.self, namespace, key, ttl: ttl)
        if let hit { await show(hit.value, true) }
        guard force || hit == nil || hit!.isStale else { return }
        do {
            let fresh = try await fetch()
            await shared.write(fresh, namespace, key)
            await show(fresh, false)
        } catch {
            if hit == nil { throw error }
        }
    }

    enum TTL {
        static let bookPage: TimeInterval = 24 * 3600
        static let authorPage: TimeInterval = 3 * 24 * 3600
        static let friends: TimeInterval = 3600
        static let profile: TimeInterval = 6 * 3600
        static let friendShelf: TimeInterval = 6 * 3600
        static let authorSearch: TimeInterval = 3 * 24 * 3600
        static let suggestions: TimeInterval = 6 * 3600
    }
}

// MARK: - Images

/// Decoded covers and avatars, kept for the session. `URLCache` already
/// keeps the bytes, but `AsyncImage` decodes again every time a row comes
/// back on screen, so covers blinked through their placeholder on every
/// scroll and pane switch.
@MainActor
final class ImageMemoryCache {
    static let shared = ImageMemoryCache()

    private let images: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 600
        return cache
    }()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    func cached(_ url: URL) -> NSImage? { images.object(forKey: url as NSURL) }

    func removeAll() { images.removeAllObjects() }

    func load(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        if let task = inFlight[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { images.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// Drop-in for `AsyncImage(url:content:)` that shows an already-loaded image
/// on the first frame instead of flashing the placeholder.
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
        if let url, let image = ImageMemoryCache.shared.cached(url) {
            _phase = State(initialValue: .success(Image(nsImage: image)))
        }
    }

    var body: some View {
        content(phase)
            .task(id: url) {
                guard let url else { phase = .empty; return }
                if let image = ImageMemoryCache.shared.cached(url) {
                    phase = .success(Image(nsImage: image))
                    return
                }
                if let image = await ImageMemoryCache.shared.load(url) {
                    phase = .success(Image(nsImage: image))
                } else {
                    phase = .failure(URLError(.cannotDecodeContentData))
                }
            }
    }
}
