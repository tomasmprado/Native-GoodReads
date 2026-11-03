import Foundation

/// Your own notes and saved quotes for a book. Kept on this Mac only —
/// Goodreads has nowhere private to put them — and included in CSV exports.
struct BookNote: Codable, Sendable, Equatable {
    var text: String = ""
    var quotes: [String] = []
    var updated = Date()

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && quotes.isEmpty
    }
}

enum BookNotes {

    private static let namespace = "notes"
    private static let key = "all"

    /// Every note, keyed by Goodreads book id.
    static func all() async -> [String: BookNote] {
        await DataCache.shared.read([String: BookNote].self, namespace, key, ttl: .infinity)?.value ?? [:]
    }

    static func note(for bookID: String) async -> BookNote {
        await all()[bookID] ?? BookNote()
    }

    static func save(_ note: BookNote, for bookID: String) async {
        await DataCache.shared.modify([String: BookNote].self, namespace, key, default: [:]) { all in
            if note.isEmpty {
                all[bookID] = nil
            } else {
                var stamped = note
                stamped.updated = Date()
                all[bookID] = stamped
            }
        }
        await SpotlightIndex.refreshNotes()
    }
}
