import Foundation

/// A change to your library made while Goodreads couldn't be reached.
enum PendingChange: Codable, Sendable, Equatable {
    case rate(bookID: String, title: String, stars: Int)
    case add(bookID: String, title: String, shelf: String)
    case remove(bookID: String, title: String, shelf: String)
    case progress(bookID: String, title: String, percent: Int?, page: Int?, note: String)
    case finish(bookID: String, title: String, rating: Int?, dateRead: Date?, note: String)

    var title: String {
        switch self {
        case .rate(_, let title, _), .add(_, let title, _), .remove(_, let title, _),
             .progress(_, let title, _, _, _), .finish(_, let title, _, _, _): title
        }
    }

    var bookID: String {
        switch self {
        case .rate(let id, _, _), .add(let id, _, _), .remove(let id, _, _),
             .progress(let id, _, _, _, _), .finish(let id, _, _, _, _): id
        }
    }

    /// A newer change that makes this one pointless: a second rating of the
    /// same book, or a newer progress update.
    func isReplaced(by newer: PendingChange) -> Bool {
        switch (self, newer) {
        case (.rate(let a, _, _), .rate(let b, _, _)): a == b
        case (.progress(let a, _, _, _, _), .progress(let b, _, _, _, _)): a == b
        case (.progress(let a, _, _, _, _), .finish(let b, _, _, _, _)): a == b
        default: false
        }
    }
}

struct QueuedChange: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    let change: PendingChange
    let date: Date
}

/// Changes waiting for the connection, kept on disk so quitting the app
/// doesn't lose them, and sent in order once Goodreads can be reached.
@MainActor
final class Outbox: ObservableObject {
    static let shared = Outbox()

    @Published private(set) var queue: [QueuedChange] = []
    @Published private(set) var isSending = false

    private var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoodreadsGUI/outbox.json")
    }

    private init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([QueuedChange].self, from: data) {
            queue = saved
        }
    }

    func add(_ change: PendingChange) {
        queue = Self.adding(change, to: queue)
        save()
    }

    /// The queue with `change` at the end and anything it replaces gone.
    nonisolated static func adding(_ change: PendingChange, to queue: [QueuedChange], now: Date = Date()) -> [QueuedChange] {
        queue.filter { !$0.change.isReplaced(by: change) } + [QueuedChange(change: change, date: now)]
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if queue.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else if let data = try? JSONEncoder().encode(queue) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Whether `error` means "no connection", so the change should wait
    /// rather than fail.
    nonisolated static func isOffline(_ error: Error) -> Bool {
        let codes: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                         .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                                         .dataNotAllowed, .internationalRoamingOff]
        if let urlError = error as? URLError { return codes.contains(urlError.code) }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return codes.contains(URLError.Code(rawValue: nsError.code)) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error { return isOffline(underlying) }
        return false
    }

    /// Sends what's waiting, oldest first. Stops at the first change that
    /// can't get through for want of a connection; one Goodreads turns down
    /// is dropped and reported.
    func send(using shelves: [Shelf], report: (String) -> Void) async {
        guard !isSending, !queue.isEmpty, Connectivity.shared.isOnline else { return }
        isSending = true
        defer { isSending = false }
        var sent = 0
        while let next = queue.first {
            do {
                try await Self.perform(next.change, shelves: shelves)
                sent += 1
            } catch where Self.isOffline(error) {
                break
            } catch {
                report(String(localized: "Couldn’t sync “\(next.change.title)”: \(error.localizedDescription)"))
            }
            queue.removeFirst()
            save()
        }
        if sent > 0 {
            Diagnostics.shared.log("outbox", "sent \(sent) change(s) made offline; \(queue.count) left")
        }
    }

    private static func perform(_ change: PendingChange, shelves: [Shelf]) async throws {
        func shelf(_ name: String) -> Shelf { shelves.first { $0.name == name } ?? Shelf.fromSlug(name) }
        switch change {
        case .rate(let id, _, let stars):
            try await ShelfService.rate(bookID: id, stars: stars)
        case .add(let id, _, let name):
            try await ShelfService.add(bookID: id, to: shelf(name))
        case .remove(let id, _, let name):
            try await ShelfService.remove(bookID: id, from: shelf(name))
        case .progress(let id, _, let percent, let page, let note):
            _ = try await ShelfService.updateProgress(bookID: id, percent: percent, page: page, note: note)
        case .finish(let id, _, let rating, let date, let note):
            try await ShelfService.finish(bookID: id, rating: rating, dateRead: date, note: note)
        }
    }
}
