import Foundation
import UserNotifications

/// Tells you when a friend starts or finishes a book. Works from each
/// friend's "currently reading" line on `/friend`: whenever the friend list
/// refreshes, a status that differs from the last one seen becomes a
/// notification. The very first refresh only records what's there, so
/// turning this on doesn't produce one notification per friend.
@MainActor
enum FriendNotifier {

    /// friend id → status signature, as last seen.
    typealias Snapshot = [String: String]

    struct Change: Equatable {
        let friendID: String
        let title: String
        let body: String
    }

    /// What changed between the last snapshot and the friends just fetched.
    /// A friend who wasn't in the old snapshot at all (new friend, or first
    /// run) is recorded silently.
    nonisolated static func changes(from old: Snapshot,
                                    to friends: [GoodreadsFriends.Friend]) -> (changes: [Change], snapshot: Snapshot) {
        var snapshot: Snapshot = [:]
        var changes: [Change] = []
        for friend in friends {
            let sig = friend.hasStatus
                ? "\(friend.statusLabel ?? "")|\(friend.statusBookTitle ?? "")"
                : ""
            snapshot[friend.id] = sig
            guard let before = old[friend.id], before != sig, !sig.isEmpty,
                  let book = friend.statusBookTitle, !book.isEmpty else { continue }
            let label = friend.statusLabel?.trimmingCharacters(in: .whitespaces).lowercased()
            let action = (label?.isEmpty == false ? label! : "is reading")
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            changes.append(Change(friendID: friend.id,
                                  title: friend.name,
                                  body: "\(action.prefix(1).uppercased() + action.dropFirst()): \(book)"))
        }
        return (changes, snapshot)
    }

    /// Called with every fresh (not cached) friend list.
    static func friendsRefreshed(_ friends: [GoodreadsFriends.Friend]) async {
        guard Preferences.shared.notifyFriendActivity, !friends.isEmpty else { return }
        let old = await DataCache.shared.read(Snapshot.self, "friends", "notified", ttl: .infinity)
        let result = changes(from: old?.value ?? [:], to: friends)
        await DataCache.shared.write(result.snapshot, "friends", "notified")
        guard old != nil else { return }      // first run: just remember

        for change in result.changes.prefix(5) {
            let content = UNMutableNotificationContent()
            content.title = change.title
            content.body = change.body
            content.sound = .default
            let request = UNNotificationRequest(identifier: "friend-\(change.friendID)-\(change.body.hashValue)",
                                                content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Asks macOS for permission; returns whether it was granted.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// While the app is open, re-checks friends every hour so notifications
    /// arrive without having to open the Friends pane.
    static func startPolling(_ model: LibraryModel) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard !Task.isCancelled, Preferences.shared.notifyFriendActivity, model.loggedIn else { continue }
                await model.loadFriends(force: true)
            }
        }
    }

    private static var pollTask: Task<Void, Never>?
}
