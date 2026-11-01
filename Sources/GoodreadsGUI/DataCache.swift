import AppKit
import SwiftUI

/// Everything the app fetches besides shelves (which have `ShelfCache`) —
/// book pages, author pages, friends, profiles, suggestions, author searches.
/// Kept in memory for the session and on disk across launches, so a screen
/// you've seen before opens instantly and refreshes behind what you see.
actor DataCache {
    static let shared = DataCache()

    struct Hit<T: Sendable>: Sendable {
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

    func read<T: Codable & Sendable>(_ type: T.Type, _ namespace: String, _ key: String,
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

    func write<T: Codable & Sendable>(_ value: T, _ namespace: String, _ key: String) {
        let now = Date()
        memory["\(namespace)/\(key)"] = (value, now)
        let file = Self.file(namespace, key)
        guard let data = try? JSONEncoder().encode(Stored(value: value, fetched: now)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Bytes on disk across this cache, the shelf cache and the URL cache.
    /// Read, change and write back in one step, so two callers changing
    /// the same value at once don't overwrite each other.
    func modify<T: Codable & Sendable>(_ type: T.Type, _ namespace: String, _ key: String,
                                       default initial: T, _ change: (inout T) -> Void) {
        var value = read(type, namespace, key, ttl: .infinity)?.value ?? initial
        change(&value)
        write(value, namespace, key)
    }

    nonisolated static func diskUsage() -> Int {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoodreadsGUI", isDirectory: true)
        var total = URLCache.shared.currentDiskUsage
        if let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in files {
                total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return total
    }

    /// Everything the app keeps to be fast: data, shelves, images.
    nonisolated static func clearEverything() async {
        await shared.clear()
        ShelfCache.clear()
        URLCache.shared.removeAllCachedResponses()
        ImageMemoryCache.shared.removeAll()
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
    ///
    /// `accept` guards against a refresh that "succeeds" with junk — a
    /// scraper that stopped matching Goodreads' markup returns an empty list
    /// rather than throwing, and that must not replace a good cached copy.
    /// A rejected result is still shown when there was nothing cached, but
    /// it's never written, so the next visit tries again.
    nonisolated static func load<T: Codable & Sendable>(
        _ namespace: String, _ key: String,
        ttl: TimeInterval, force: Bool = false,
        accept: @escaping @Sendable (T) -> Bool = { _ in true },
        fetch: @escaping @Sendable () async throws -> T,
        show: @MainActor @escaping (T, _ fromCache: Bool) -> Void
    ) async throws {
        let hit = await shared.read(T.self, namespace, key, ttl: ttl)
        if let hit { await show(hit.value, true) }
        guard force || hit == nil || hit!.isStale else { return }
        do {
            let fresh = try await fetch()
            guard accept(fresh) else {
                if hit == nil { await show(fresh, false) }
                return
            }
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
    nonisolated static let shared = ImageMemoryCache()

    // NSCache is thread-safe, so lookups don't need the main actor — a view's
    // init (which reads it) isn't main-actor-isolated on older toolchains.
    nonisolated(unsafe) private let images: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 600
        return cache
    }()
    // Bytes, not NSImage — NSImage only became Sendable in macOS 14, and the
    // download runs off the main actor. Decoding happens back on main.
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    nonisolated private init() { }

    nonisolated func cached(_ url: URL) -> NSImage? { images.object(forKey: url as NSURL) }

    nonisolated func removeAll() { images.removeAllObjects() }

    /// Warms covers that are about to scroll into view, a few at a time so
    /// it never competes with what's on screen.
    func prefetch(_ urls: [URL]) {
        let todo = urls.filter { cached($0) == nil && inFlight[$0] == nil }
        guard !todo.isEmpty else { return }
        Task {
            var index = 0
            while index < todo.count {
                let batch = todo[index..<min(index + 4, todo.count)]
                await withTaskGroup(of: Void.self) { group in
                    for url in batch { group.addTask { _ = await self.load(url) } }
                }
                index += 4
            }
        }
    }

    func load(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        let task: Task<Data?, Never>
        if let running = inFlight[url] {
            task = running
        } else {
            task = Task.detached(priority: .utility) {
                try? await URLSession.shared.data(from: url).0
            }
            inFlight[url] = task
        }
        let data = await task.value
        inFlight[url] = nil
        if let image = cached(url) { return image }   // another waiter decoded it
        guard let data, let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: url as NSURL)
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
            .accessibilityHidden(true)
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
