import Foundation

/// Which of your friends have read or are reading which books — built from
/// their Read and Currently Reading shelves, so Book Details can show
/// "Friends who read this" without a fetch per book.
struct FriendLibrary: Codable, Sendable, Identifiable {
    let friendID: String
    let name: String
    let avatarURL: URL?
    let profileURL: URL?
    /// Book id → what they did with it.
    var books: [String: FriendBook]
    var fetched: Date

    var id: String { friendID }
}

struct FriendBook: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case read, reading }
    let state: State
    /// 1–5, or nil when they didn't rate it.
    let rating: Int?
}

/// One friend's line in Book Details.
struct FriendReading: Identifiable, Equatable {
    let friendID: String
    let name: String
    let avatarURL: URL?
    let profileURL: URL?
    let book: FriendBook

    var id: String { friendID }
}

enum FriendsBooks {
    private static let namespace = "friends-books"
    private static let key = "index"
    /// Refreshed in the background once it's older than this.
    static let refreshAfter: TimeInterval = 3 * 24 * 3600

    static func index() async -> [String: FriendLibrary] {
        await DataCache.shared.read([String: FriendLibrary].self, namespace, key, ttl: .infinity)?.value ?? [:]
    }

    static func save(_ index: [String: FriendLibrary]) async {
        await DataCache.shared.write(index, namespace, key)
    }

    /// The friends who have `bookID`, readers first, then by their rating.
    static func friends(with bookID: String, in index: [String: FriendLibrary]) -> [FriendReading] {
        index.values.compactMap { library -> FriendReading? in
            guard let book = library.books[bookID] else { return nil }
            return FriendReading(friendID: library.friendID, name: library.name, avatarURL: library.avatarURL,
                                 profileURL: library.profileURL, book: book)
        }
        .sorted { a, b in
            if a.book.state != b.book.state { return a.book.state == .read }
            if (a.book.rating ?? 0) != (b.book.rating ?? 0) { return (a.book.rating ?? 0) > (b.book.rating ?? 0) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// One friend's books from their two shelves.
    static func library(for friend: GoodreadsFriends.Friend, read: [ShelfEntry],
                        reading: [ShelfEntry], fetched: Date = Date()) -> FriendLibrary {
        var books: [String: FriendBook] = [:]
        for entry in read {
            books[entry.bookID] = FriendBook(state: .read, rating: (entry.rating ?? 0) > 0 ? entry.rating : nil)
        }
        for entry in reading where books[entry.bookID] == nil {
            books[entry.bookID] = FriendBook(state: .reading, rating: nil)
        }
        return FriendLibrary(friendID: friend.id, name: friend.name, avatarURL: friend.avatarURL,
                             profileURL: friend.profileURL, books: books, fetched: fetched)
    }

    /// Fetches every friend's shelves, a few friends at a time, saving as it
    /// goes. A friend whose shelves can't be read (private, or a failed
    /// fetch) keeps what was there before.
    @MainActor
    static func sync(_ friends: [GoodreadsFriends.Friend],
                     progress: @MainActor (_ done: Int, _ total: Int) -> Void) async -> [String: FriendLibrary] {
        var index = await self.index()
        // Friends no longer on the list drop out.
        let ids = Set(friends.map(\.id))
        index = index.filter { ids.contains($0.key) }

        var done = 0
        progress(0, friends.count)
        var pending = friends[...]
        while !pending.isEmpty, !Task.isCancelled {
            let batch = pending.prefix(3)
            pending = pending.dropFirst(3)
            let tasks = batch.map { friend in
                Task { @MainActor () -> FriendLibrary? in
                    let userID = GoodreadsFriends.userID(from: friend.profileURL) ?? friend.id
                    guard let read = try? await ShelfLibrary.load(.read, ofUser: userID) else { return nil }
                    let reading = (try? await ShelfLibrary.load(.currentlyReading, ofUser: userID)) ?? []
                    return library(for: friend, read: read, reading: reading)
                }
            }
            var results: [FriendLibrary] = []
            for task in tasks {
                if let library = await task.value { results.append(library) }
            }
            for library in results { index[library.friendID] = library }
            done += batch.count
            progress(done, friends.count)
            await save(index)
        }
        return index
    }

    static func isStale(_ index: [String: FriendLibrary], now: Date = Date()) -> Bool {
        guard let oldest = index.values.map(\.fetched).min() else { return true }
        return now.timeIntervalSince(oldest) > refreshAfter
    }
}
